defmodule Liteskill.DataSources.DocumentSyncWorkerTest do
  use Liteskill.DataCase, async: false
  use Oban.Testing, repo: Liteskill.Repo

  alias Liteskill.Rag
  alias Liteskill.Rag.{CohereClient, Chunk}
  alias Liteskill.DataSources
  alias Liteskill.Rag.DocumentSyncWorker

  import Ecto.Query

  setup do
    {:ok, owner} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "doc-sync-#{System.unique_integer([:positive])}@example.com",
        name: "Owner",
        oidc_sub: "doc-sync-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, source} =
      DataSources.create_source(%{name: "Test Source", source_type: "manual"}, owner.id)

    %{owner: owner, source: source}
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
    test "creates RAG collection, source, document, and chunks", %{owner: owner, source: source} do
      {:ok, doc} =
        DataSources.create_document(
          source.id,
          %{title: "Test Doc", content: "Some content for RAG embedding."},
          owner.id
        )

      stub_embed(1)

      args = %{
        "document_id" => doc.id,
        "source_name" => source.name,
        "user_id" => owner.id,
        "action" => "upsert",
        "plug" => true
      }

      assert :ok = perform_job(DocumentSyncWorker, args)

      # RAG collection created with source name
      collections = Rag.list_collections(owner.id)
      coll = Enum.find(collections, &(&1.name == source.name))
      assert coll

      # RAG source created
      {:ok, sources} = Rag.list_sources(coll.id, owner.id)
      rag_source = Enum.find(sources, &(&1.name == source.name))
      assert rag_source

      # RAG document created with source_document_id metadata
      {:ok, rag_doc} = Rag.find_rag_document_by_source_doc_id(doc.id, owner.id)
      assert rag_doc.title == "Test Doc"
      assert rag_doc.metadata["source_document_id"] == doc.id
      assert rag_doc.status == "embedded"

      # Chunks created
      chunks = Repo.all(from(c in Chunk, where: c.document_id == ^rag_doc.id))
      assert chunks != []
    end

    test "re-upsert replaces old RAG document", %{owner: owner, source: source} do
      {:ok, doc} =
        DataSources.create_document(
          source.id,
          %{title: "Evolving Doc", content: "Original."},
          owner.id
        )

      stub_embed(1)

      args = %{
        "document_id" => doc.id,
        "source_name" => source.name,
        "user_id" => owner.id,
        "action" => "upsert",
        "plug" => true
      }

      assert :ok = perform_job(DocumentSyncWorker, args)
      {:ok, old_rag_doc} = Rag.find_rag_document_by_source_doc_id(doc.id, owner.id)

      # Update content
      {:ok, _} = DataSources.update_document(doc.id, %{content: "Updated."}, owner.id)
      stub_embed(1)
      assert :ok = perform_job(DocumentSyncWorker, args)

      # Old doc gone, new doc exists
      assert {:error, :not_found} = Rag.get_document(old_rag_doc.id, owner.id)
      {:ok, new_rag_doc} = Rag.find_rag_document_by_source_doc_id(doc.id, owner.id)
      assert new_rag_doc.id != old_rag_doc.id
    end

    test "no-op for empty content", %{owner: owner, source: source} do
      {:ok, doc} =
        DataSources.create_document(
          source.id,
          %{title: "Empty", content: ""},
          owner.id
        )

      args = %{
        "document_id" => doc.id,
        "source_name" => source.name,
        "user_id" => owner.id,
        "action" => "upsert",
        "plug" => true
      }

      assert :ok = perform_job(DocumentSyncWorker, args)
      assert {:error, :not_found} = Rag.find_rag_document_by_source_doc_id(doc.id, owner.id)
    end

    test "no-op for nonexistent document", %{owner: owner} do
      args = %{
        "document_id" => Ecto.UUID.generate(),
        "source_name" => "Test",
        "user_id" => owner.id,
        "action" => "upsert",
        "plug" => true
      }

      assert :ok = perform_job(DocumentSyncWorker, args)
    end
  end

  describe "perform/1 delete" do
    test "removes RAG document and chunks", %{owner: owner, source: source} do
      {:ok, doc} =
        DataSources.create_document(
          source.id,
          %{title: "Delete Me", content: "Content to delete."},
          owner.id
        )

      stub_embed(1)

      upsert_args = %{
        "document_id" => doc.id,
        "source_name" => source.name,
        "user_id" => owner.id,
        "action" => "upsert",
        "plug" => true
      }

      assert :ok = perform_job(DocumentSyncWorker, upsert_args)
      {:ok, rag_doc} = Rag.find_rag_document_by_source_doc_id(doc.id, owner.id)
      chunks = Repo.all(from(c in Chunk, where: c.document_id == ^rag_doc.id))
      assert chunks != []

      delete_args = %{
        "document_id" => doc.id,
        "source_name" => source.name,
        "user_id" => owner.id,
        "action" => "delete",
        "plug" => true
      }

      assert :ok = perform_job(DocumentSyncWorker, delete_args)

      assert {:error, :not_found} = Rag.find_rag_document_by_source_doc_id(doc.id, owner.id)
      remaining = Repo.all(from(c in Chunk, where: c.document_id == ^rag_doc.id))
      assert remaining == []
    end

    test "no-op for nonexistent document", %{owner: owner} do
      args = %{
        "document_id" => Ecto.UUID.generate(),
        "source_name" => "Test",
        "user_id" => owner.id,
        "action" => "delete",
        "plug" => true
      }

      assert :ok = perform_job(DocumentSyncWorker, args)
    end
  end
end
