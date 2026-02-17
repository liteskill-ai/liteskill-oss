defmodule Liteskill.Rag.WikiSyncWorkerTest do
  use Liteskill.DataCase, async: false
  use Oban.Testing, repo: Liteskill.Repo

  alias Liteskill.Rag
  alias Liteskill.Rag.{WikiSyncWorker, CohereClient, Chunk}
  alias Liteskill.DataSources

  import Ecto.Query

  setup do
    {:ok, owner} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "wiki-sync-#{System.unique_integer([:positive])}@example.com",
        name: "Owner",
        oidc_sub: "wiki-sync-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{owner: owner}
  end

  defp stub_embed(count) do
    embeddings = List.duplicate(List.duplicate(0.1, 1024), count)

    Req.Test.stub(CohereClient, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"embeddings" => %{"float" => embeddings}})
      )
    end)
  end

  describe "perform/1 upsert" do
    test "creates collection, source, rag document, and chunks", %{owner: owner} do
      {:ok, wiki_doc} =
        DataSources.create_document(
          "builtin:wiki",
          %{title: "Test Page", content: "Hello world. This is wiki content for RAG."},
          owner.id
        )

      stub_embed(1)

      args = %{
        "wiki_document_id" => wiki_doc.id,
        "user_id" => owner.id,
        "action" => "upsert",
        "plug" => true
      }

      assert :ok = perform_job(WikiSyncWorker, args)

      # Wiki collection created
      collections = Rag.list_collections(owner.id)
      wiki_coll = Enum.find(collections, &(&1.name == "Wiki"))
      assert wiki_coll

      # Wiki source created
      {:ok, sources} = Rag.list_sources(wiki_coll.id, owner.id)
      wiki_source = Enum.find(sources, &(&1.name == "wiki"))
      assert wiki_source

      # RAG document created with wiki_document_id metadata
      {:ok, rag_doc} = Rag.find_rag_document_by_wiki_id(wiki_doc.id, owner.id)
      assert rag_doc.title == "Test Page"
      assert rag_doc.metadata["wiki_document_id"] == wiki_doc.id
      assert rag_doc.status == "embedded"

      # Chunks created
      chunks = Repo.all(from(c in Chunk, where: c.document_id == ^rag_doc.id))
      assert chunks != []
    end

    test "stores wiki_space_id in RAG document metadata", %{owner: owner} do
      # Create a space (root doc) and a child page
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "My Space"}, owner.id)

      {:ok, child} =
        DataSources.create_child_document(
          "builtin:wiki",
          space.id,
          %{title: "Child Page", content: "Child content for RAG."},
          owner.id
        )

      stub_embed(1)

      args = %{
        "wiki_document_id" => child.id,
        "user_id" => owner.id,
        "action" => "upsert",
        "plug" => true
      }

      assert :ok = perform_job(WikiSyncWorker, args)

      {:ok, rag_doc} = Rag.find_rag_document_by_wiki_id(child.id, owner.id)
      assert rag_doc.metadata["wiki_space_id"] == space.id
    end

    test "stores wiki_space_id as self for root space doc", %{owner: owner} do
      {:ok, space} =
        DataSources.create_document(
          "builtin:wiki",
          %{title: "Root Space", content: "Root space content."},
          owner.id
        )

      stub_embed(1)

      args = %{
        "wiki_document_id" => space.id,
        "user_id" => owner.id,
        "action" => "upsert",
        "plug" => true
      }

      assert :ok = perform_job(WikiSyncWorker, args)

      {:ok, rag_doc} = Rag.find_rag_document_by_wiki_id(space.id, owner.id)
      assert rag_doc.metadata["wiki_space_id"] == space.id
    end

    test "re-upsert replaces old chunks and document", %{owner: owner} do
      {:ok, wiki_doc} =
        DataSources.create_document(
          "builtin:wiki",
          %{title: "Evolving Page", content: "Original content."},
          owner.id
        )

      stub_embed(1)

      args = %{
        "wiki_document_id" => wiki_doc.id,
        "user_id" => owner.id,
        "action" => "upsert",
        "plug" => true
      }

      assert :ok = perform_job(WikiSyncWorker, args)

      {:ok, old_rag_doc} = Rag.find_rag_document_by_wiki_id(wiki_doc.id, owner.id)
      old_rag_doc_id = old_rag_doc.id

      # Update wiki page
      {:ok, _} =
        DataSources.update_document(wiki_doc.id, %{content: "Updated content."}, owner.id)

      stub_embed(1)
      assert :ok = perform_job(WikiSyncWorker, args)

      # Old document should be gone
      assert {:error, :not_found} = Rag.get_document(old_rag_doc_id, owner.id)

      # New document exists
      {:ok, new_rag_doc} = Rag.find_rag_document_by_wiki_id(wiki_doc.id, owner.id)
      assert new_rag_doc.id != old_rag_doc_id
      assert new_rag_doc.status == "embedded"
    end

    test "no-op for wiki page with empty content", %{owner: owner} do
      {:ok, wiki_doc} =
        DataSources.create_document("builtin:wiki", %{title: "Empty Page", content: ""}, owner.id)

      args = %{
        "wiki_document_id" => wiki_doc.id,
        "user_id" => owner.id,
        "action" => "upsert",
        "plug" => true
      }

      assert :ok = perform_job(WikiSyncWorker, args)

      # No RAG document created
      assert {:error, :not_found} = Rag.find_rag_document_by_wiki_id(wiki_doc.id, owner.id)
    end

    test "no-op for wiki page with nil content", %{owner: owner} do
      {:ok, wiki_doc} =
        DataSources.create_document("builtin:wiki", %{title: "Nil Page"}, owner.id)

      args = %{
        "wiki_document_id" => wiki_doc.id,
        "user_id" => owner.id,
        "action" => "upsert",
        "plug" => true
      }

      assert :ok = perform_job(WikiSyncWorker, args)
      assert {:error, :not_found} = Rag.find_rag_document_by_wiki_id(wiki_doc.id, owner.id)
    end

    test "no-op for nonexistent wiki document", %{owner: owner} do
      args = %{
        "wiki_document_id" => Ecto.UUID.generate(),
        "user_id" => owner.id,
        "action" => "upsert",
        "plug" => true
      }

      assert :ok = perform_job(WikiSyncWorker, args)
    end

    test "returns error when embed_chunks fails", %{owner: owner} do
      {:ok, wiki_doc} =
        DataSources.create_document(
          "builtin:wiki",
          %{title: "Embed Fail Page", content: "Some content to chunk."},
          owner.id
        )

      Req.Test.stub(CohereClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"message" => "embed error"}))
      end)

      args = %{
        "wiki_document_id" => wiki_doc.id,
        "user_id" => owner.id,
        "action" => "upsert",
        "plug" => true
      }

      assert {:error, _} = perform_job(WikiSyncWorker, args)
    end
  end

  describe "perform/1 delete" do
    test "removes rag document and chunks", %{owner: owner} do
      {:ok, wiki_doc} =
        DataSources.create_document(
          "builtin:wiki",
          %{title: "To Delete", content: "Delete me."},
          owner.id
        )

      stub_embed(1)

      upsert_args = %{
        "wiki_document_id" => wiki_doc.id,
        "user_id" => owner.id,
        "action" => "upsert",
        "plug" => true
      }

      assert :ok = perform_job(WikiSyncWorker, upsert_args)

      {:ok, rag_doc} = Rag.find_rag_document_by_wiki_id(wiki_doc.id, owner.id)
      chunks = Repo.all(from(c in Chunk, where: c.document_id == ^rag_doc.id))
      assert chunks != []

      delete_args = %{
        "wiki_document_id" => wiki_doc.id,
        "user_id" => owner.id,
        "action" => "delete"
      }

      assert :ok = perform_job(WikiSyncWorker, delete_args)

      # RAG document gone
      assert {:error, :not_found} = Rag.find_rag_document_by_wiki_id(wiki_doc.id, owner.id)

      # Chunks gone
      remaining = Repo.all(from(c in Chunk, where: c.document_id == ^rag_doc.id))
      assert remaining == []
    end

    test "no-op for nonexistent wiki document", %{owner: owner} do
      args = %{
        "wiki_document_id" => Ecto.UUID.generate(),
        "user_id" => owner.id,
        "action" => "delete"
      }

      assert :ok = perform_job(WikiSyncWorker, args)
    end
  end
end
