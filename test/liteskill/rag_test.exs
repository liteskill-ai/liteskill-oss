defmodule Liteskill.RagTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Rag
  alias Liteskill.Rag.{Collection, Source, Document, Chunk, CohereClient}

  setup do
    {:ok, owner} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "rag-owner-#{System.unique_integer([:positive])}@example.com",
        name: "Owner",
        oidc_sub: "rag-owner-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, other} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "rag-other-#{System.unique_integer([:positive])}@example.com",
        name: "Other",
        oidc_sub: "rag-other-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{owner: owner, other: other}
  end

  defp create_collection(user_id, attrs \\ %{}) do
    default = %{name: "Test Collection"}
    Rag.create_collection(Map.merge(default, attrs), user_id)
  end

  defp create_source(collection_id, user_id, attrs \\ %{}) do
    default = %{name: "Test Source"}
    Rag.create_source(collection_id, Map.merge(default, attrs), user_id)
  end

  defp create_document(source_id, user_id, attrs \\ %{}) do
    default = %{title: "Test Document"}
    Rag.create_document(source_id, Map.merge(default, attrs), user_id)
  end

  defp stub_embed(embeddings) do
    Req.Test.stub(CohereClient, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"embeddings" => %{"float" => embeddings}})
      )
    end)
  end

  defp stub_rerank(results) do
    Req.Test.stub(CohereClient, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"results" => results}))
    end)
  end

  # --- Collections ---

  describe "create_collection/2" do
    test "creates collection with valid attrs", %{owner: owner} do
      assert {:ok, %Collection{} = coll} = create_collection(owner.id)
      assert coll.name == "Test Collection"
      assert coll.user_id == owner.id
      assert coll.embedding_dimensions == 1024
    end

    test "creates collection with custom dimensions", %{owner: owner} do
      assert {:ok, coll} = create_collection(owner.id, %{embedding_dimensions: 512})
      assert coll.embedding_dimensions == 512
    end

    test "fails with invalid dimensions", %{owner: owner} do
      assert {:error, %Ecto.Changeset{}} =
               create_collection(owner.id, %{embedding_dimensions: 999})
    end

    test "fails without name", %{owner: owner} do
      assert {:error, %Ecto.Changeset{}} =
               Rag.create_collection(%{}, owner.id)
    end
  end

  describe "list_collections/1" do
    test "lists own collections", %{owner: owner} do
      {:ok, _} = create_collection(owner.id, %{name: "A"})
      {:ok, _} = create_collection(owner.id, %{name: "B"})

      collections = Rag.list_collections(owner.id)
      assert length(collections) == 2
      assert Enum.map(collections, & &1.name) == ["A", "B"]
    end

    test "excludes other users' collections", %{owner: owner, other: other} do
      {:ok, _} = create_collection(owner.id)
      {:ok, _} = create_collection(other.id)

      assert length(Rag.list_collections(owner.id)) == 1
    end
  end

  describe "list_accessible_collections/1" do
    test "includes own collections", %{owner: owner} do
      {:ok, _} = create_collection(owner.id, %{name: "My Coll"})

      colls = Rag.list_accessible_collections(owner.id)
      assert length(colls) == 1
      assert hd(colls).name == "My Coll"
    end

    test "includes wiki collections from shared wiki spaces", %{owner: owner, other: other} do
      # Owner creates a wiki space and shares it with other
      {:ok, space} =
        Liteskill.DataSources.create_document("builtin:wiki", %{title: "Shared"}, owner.id)

      {:ok, _} =
        Liteskill.Authorization.grant_access("wiki_space", space.id, owner.id, other.id, "viewer")

      # Owner has a Wiki collection (created by wiki sync)
      {:ok, _wiki_coll} = Rag.find_or_create_wiki_collection(owner.id)

      # Other user should see owner's Wiki collection
      colls = Rag.list_accessible_collections(other.id)
      wiki_names = Enum.map(colls, & &1.name)
      assert "Wiki" in wiki_names
    end

    test "excludes wiki collections from unshared spaces", %{owner: owner, other: other} do
      # Owner creates a wiki space but does NOT share
      {:ok, _space} =
        Liteskill.DataSources.create_document("builtin:wiki", %{title: "Private"}, owner.id)

      {:ok, _} = Rag.find_or_create_wiki_collection(owner.id)

      colls = Rag.list_accessible_collections(other.id)
      assert colls == []
    end

    test "does not duplicate own Wiki collection", %{owner: owner} do
      {:ok, _} = Rag.find_or_create_wiki_collection(owner.id)

      colls = Rag.list_accessible_collections(owner.id)
      wiki_count = Enum.count(colls, &(&1.name == "Wiki"))
      assert wiki_count == 1
    end
  end

  describe "search_accessible/4" do
    test "returns results from owned collection", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)

      embedding = List.duplicate(0.1, 1024)
      agent = Agent.start_link(fn -> :embed end) |> elem(1)

      Req.Test.stub(CohereClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        response =
          case Agent.get_and_update(agent, fn s -> {s, :done} end) do
            :embed ->
              %{"embeddings" => %{"float" => [embedding]}}

            :done ->
              if Map.has_key?(decoded, "query") do
                %{"results" => [%{"index" => 0, "relevance_score" => 0.95}]}
              else
                %{"embeddings" => %{"float" => [embedding]}}
              end
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end)

      chunks = [%{content: "owned chunk", position: 0}]
      {:ok, _} = Rag.embed_chunks(doc.id, chunks, owner.id, plug: {Req.Test, CohereClient})

      assert {:ok, results} =
               Rag.search_accessible(coll.id, "test", owner.id,
                 plug: {Req.Test, CohereClient},
                 top_n: 5,
                 search_limit: 20
               )

      assert results != []
    end

    test "returns results from shared wiki collection", %{owner: owner, other: other} do
      {:ok, space} =
        Liteskill.DataSources.create_document("builtin:wiki", %{title: "Shared"}, owner.id)

      {:ok, _} =
        Liteskill.Authorization.grant_access("wiki_space", space.id, owner.id, other.id, "viewer")

      {:ok, coll} = Rag.find_or_create_wiki_collection(owner.id)
      {:ok, source} = Rag.find_or_create_wiki_source(coll.id, owner.id)

      {:ok, rag_doc} =
        create_document(source.id, owner.id, %{
          title: "Shared Page",
          metadata: %{"wiki_document_id" => Ecto.UUID.generate(), "wiki_space_id" => space.id}
        })

      embedding = List.duplicate(0.1, 1024)
      agent = Agent.start_link(fn -> :embed end) |> elem(1)

      Req.Test.stub(CohereClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        response =
          case Agent.get_and_update(agent, fn s -> {s, :done} end) do
            :embed ->
              %{"embeddings" => %{"float" => [embedding]}}

            :done ->
              if Map.has_key?(decoded, "query") do
                %{"results" => [%{"index" => 0, "relevance_score" => 0.9}]}
              else
                %{"embeddings" => %{"float" => [embedding]}}
              end
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end)

      chunks = [%{content: "shared wiki chunk", position: 0}]
      {:ok, _} = Rag.embed_chunks(rag_doc.id, chunks, owner.id, plug: {Req.Test, CohereClient})

      # Other user can search owner's collection and see shared wiki chunks
      assert {:ok, results} =
               Rag.search_accessible(coll.id, "wiki", other.id,
                 plug: {Req.Test, CohereClient},
                 top_n: 5,
                 search_limit: 20
               )

      assert results != []
      assert hd(results).chunk.content == "shared wiki chunk"
    end

    test "filters out chunks from non-accessible wiki spaces", %{owner: owner, other: other} do
      {:ok, space} =
        Liteskill.DataSources.create_document("builtin:wiki", %{title: "Private"}, owner.id)

      {:ok, coll} = Rag.find_or_create_wiki_collection(owner.id)
      {:ok, source} = Rag.find_or_create_wiki_source(coll.id, owner.id)

      {:ok, rag_doc} =
        create_document(source.id, owner.id, %{
          title: "Private Page",
          metadata: %{"wiki_document_id" => Ecto.UUID.generate(), "wiki_space_id" => space.id}
        })

      embedding = List.duplicate(0.1, 1024)
      agent = Agent.start_link(fn -> :embed end) |> elem(1)

      Req.Test.stub(CohereClient, fn conn ->
        response =
          case Agent.get_and_update(agent, fn s -> {s, :done} end) do
            :embed -> %{"embeddings" => %{"float" => [embedding]}}
            :done -> %{"embeddings" => %{"float" => [embedding]}}
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end)

      chunks = [%{content: "private chunk", position: 0}]
      {:ok, _} = Rag.embed_chunks(rag_doc.id, chunks, owner.id, plug: {Req.Test, CohereClient})

      # Other user cannot see chunks (no ACL)
      assert {:ok, []} =
               Rag.search_accessible(coll.id, "test", other.id,
                 plug: {Req.Test, CohereClient},
                 top_n: 5,
                 search_limit: 20
               )
    end

    test "falls back when rerank fails", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)

      embedding = List.duplicate(0.1, 1024)
      agent = Agent.start_link(fn -> 0 end) |> elem(1)

      Req.Test.stub(CohereClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        call_num = Agent.get_and_update(agent, fn n -> {n, n + 1} end)

        cond do
          call_num == 0 ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              200,
              Jason.encode!(%{"embeddings" => %{"float" => [embedding]}})
            )

          Map.has_key?(decoded, "input_type") ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              200,
              Jason.encode!(%{"embeddings" => %{"float" => [embedding]}})
            )

          Map.has_key?(decoded, "query") ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(500, Jason.encode!(%{"message" => "rerank failed"}))
        end
      end)

      chunks = [%{content: "fallback chunk", position: 0}]
      {:ok, _} = Rag.embed_chunks(doc.id, chunks, owner.id, plug: {Req.Test, CohereClient})

      assert {:ok, results} =
               Rag.search_accessible(coll.id, "test", owner.id,
                 plug: {Req.Test, CohereClient},
                 top_n: 5,
                 search_limit: 20
               )

      assert results != []
      assert Enum.all?(results, fn r -> r.relevance_score == nil end)
    end

    test "returns error on embed failure", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)

      Req.Test.stub(CohereClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"message" => "error"}))
      end)

      assert {:error, %{status: 500}} =
               Rag.search_accessible(coll.id, "query", owner.id, plug: {Req.Test, CohereClient})
    end

    test "returns not_found for nonexistent collection", %{owner: owner} do
      assert {:error, :not_found} =
               Rag.search_accessible(Ecto.UUID.generate(), "q", owner.id)
    end
  end

  describe "get_collection/2" do
    test "returns own collection", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      assert {:ok, found} = Rag.get_collection(coll.id, owner.id)
      assert found.id == coll.id
    end

    test "returns not_found for other user", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      assert {:error, :not_found} = Rag.get_collection(coll.id, other.id)
    end

    test "returns not_found for nonexistent id", %{owner: owner} do
      assert {:error, :not_found} = Rag.get_collection(Ecto.UUID.generate(), owner.id)
    end
  end

  describe "update_collection/3" do
    test "owner can update", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      assert {:ok, updated} = Rag.update_collection(coll.id, %{name: "Updated"}, owner.id)
      assert updated.name == "Updated"
    end

    test "non-owner cannot update", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      assert {:error, :not_found} = Rag.update_collection(coll.id, %{name: "Hacked"}, other.id)
    end

    test "returns changeset error for invalid update", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)

      assert {:error, %Ecto.Changeset{}} =
               Rag.update_collection(coll.id, %{embedding_dimensions: 999}, owner.id)
    end
  end

  describe "delete_collection/2" do
    test "owner can delete", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      assert {:ok, _} = Rag.delete_collection(coll.id, owner.id)
      assert Rag.list_collections(owner.id) == []
    end

    test "non-owner cannot delete", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      assert {:error, :not_found} = Rag.delete_collection(coll.id, other.id)
    end
  end

  # --- Sources ---

  describe "create_source/3" do
    test "creates source with valid attrs", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      assert {:ok, %Source{} = source} = create_source(coll.id, owner.id)
      assert source.name == "Test Source"
      assert source.source_type == "manual"
      assert source.collection_id == coll.id
    end

    test "creates source with custom type", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)

      assert {:ok, source} =
               create_source(coll.id, owner.id, %{source_type: "upload"})

      assert source.source_type == "upload"
    end

    test "fails with invalid source_type", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)

      assert {:error, %Ecto.Changeset{}} =
               create_source(coll.id, owner.id, %{source_type: "invalid"})
    end

    test "fails if collection belongs to other user", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      assert {:error, :not_found} = create_source(coll.id, other.id)
    end
  end

  describe "list_sources/2" do
    test "lists sources in collection", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, _} = create_source(coll.id, owner.id, %{name: "A"})
      {:ok, _} = create_source(coll.id, owner.id, %{name: "B"})

      assert {:ok, sources} = Rag.list_sources(coll.id, owner.id)
      assert length(sources) == 2
      assert Enum.map(sources, & &1.name) == ["A", "B"]
    end

    test "non-owner cannot list", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      assert {:error, :not_found} = Rag.list_sources(coll.id, other.id)
    end
  end

  describe "get_source/2" do
    test "returns own source", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      assert {:ok, found} = Rag.get_source(source.id, owner.id)
      assert found.id == source.id
    end

    test "returns not_found for other user", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      assert {:error, :not_found} = Rag.get_source(source.id, other.id)
    end

    test "returns not_found for nonexistent id", %{owner: owner} do
      assert {:error, :not_found} = Rag.get_source(Ecto.UUID.generate(), owner.id)
    end
  end

  describe "update_source/3" do
    test "owner can update", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      assert {:ok, updated} = Rag.update_source(source.id, %{name: "Updated"}, owner.id)
      assert updated.name == "Updated"
    end

    test "non-owner cannot update", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      assert {:error, :not_found} = Rag.update_source(source.id, %{name: "X"}, other.id)
    end
  end

  describe "delete_source/2" do
    test "owner can delete", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      assert {:ok, _} = Rag.delete_source(source.id, owner.id)
      assert {:ok, []} = Rag.list_sources(coll.id, owner.id)
    end

    test "non-owner cannot delete", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      assert {:error, :not_found} = Rag.delete_source(source.id, other.id)
    end
  end

  # --- Documents ---

  describe "create_document/3" do
    test "creates document with valid attrs", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      assert {:ok, %Document{} = doc} = create_document(source.id, owner.id)
      assert doc.title == "Test Document"
      assert doc.status == "pending"
      assert doc.chunk_count == 0
    end

    test "creates document with content and metadata", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)

      assert {:ok, doc} =
               create_document(source.id, owner.id, %{
                 content: "full text here",
                 metadata: %{"key" => "value"}
               })

      assert doc.content == "full text here"
      assert doc.metadata == %{"key" => "value"}
    end

    test "fails if source belongs to other user", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      assert {:error, :not_found} = create_document(source.id, other.id)
    end
  end

  describe "list_documents/2" do
    test "lists documents in source", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, _} = create_document(source.id, owner.id, %{title: "A"})
      {:ok, _} = create_document(source.id, owner.id, %{title: "B"})

      assert {:ok, docs} = Rag.list_documents(source.id, owner.id)
      assert length(docs) == 2
      assert Enum.map(docs, & &1.title) == ["A", "B"]
    end

    test "non-owner cannot list", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      assert {:error, :not_found} = Rag.list_documents(source.id, other.id)
    end
  end

  describe "get_document/2" do
    test "returns own document", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)
      assert {:ok, found} = Rag.get_document(doc.id, owner.id)
      assert found.id == doc.id
    end

    test "returns not_found for other user", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)
      assert {:error, :not_found} = Rag.get_document(doc.id, other.id)
    end

    test "returns not_found for nonexistent id", %{owner: owner} do
      assert {:error, :not_found} = Rag.get_document(Ecto.UUID.generate(), owner.id)
    end
  end

  describe "delete_document/2" do
    test "owner can delete", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)
      assert {:ok, _} = Rag.delete_document(doc.id, owner.id)
      assert {:ok, []} = Rag.list_documents(source.id, owner.id)
    end

    test "non-owner cannot delete", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)
      assert {:error, :not_found} = Rag.delete_document(doc.id, other.id)
    end
  end

  # --- Chunk Changeset ---

  describe "Chunk.changeset/2" do
    test "validates required fields" do
      changeset = Chunk.changeset(%Chunk{}, %{})
      refute changeset.valid?
      assert errors_on(changeset)[:content]
      assert errors_on(changeset)[:position]
      assert errors_on(changeset)[:document_id]
    end

    test "accepts valid attrs" do
      changeset =
        Chunk.changeset(%Chunk{}, %{
          content: "test",
          position: 0,
          document_id: Ecto.UUID.generate()
        })

      assert changeset.valid?
    end
  end

  # --- Embed Chunks ---

  describe "embed_chunks/4" do
    test "embeds chunks and updates document status", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)

      emb1 = List.duplicate(0.1, 1024)
      emb2 = List.duplicate(0.2, 1024)
      stub_embed([emb1, emb2])

      chunks = [
        %{content: "chunk one", position: 0, metadata: %{"page" => 1}, token_count: 10},
        %{content: "chunk two", position: 1, metadata: %{"page" => 2}, token_count: 12}
      ]

      assert {:ok, updated_doc} =
               Rag.embed_chunks(doc.id, chunks, owner.id, plug: {Req.Test, CohereClient})

      assert updated_doc.status == "embedded"
      assert updated_doc.chunk_count == 2

      # Verify chunks were inserted
      db_chunks =
        Chunk
        |> where([c], c.document_id == ^doc.id)
        |> order_by([c], asc: c.position)
        |> Repo.all()

      assert length(db_chunks) == 2
      assert Enum.at(db_chunks, 0).content == "chunk one"
      assert Enum.at(db_chunks, 0).position == 0
      assert Enum.at(db_chunks, 0).token_count == 10
      assert Enum.at(db_chunks, 0).embedding != nil
      assert Enum.at(db_chunks, 1).content == "chunk two"
    end

    test "sets document status to error on embed failure", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)

      Req.Test.stub(CohereClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"message" => "server error"}))
      end)

      chunks = [%{content: "chunk", position: 0}]

      assert {:error, %{status: 500}} =
               Rag.embed_chunks(doc.id, chunks, owner.id, plug: {Req.Test, CohereClient})

      # Document status should be "error"
      {:ok, reloaded} = Rag.get_document(doc.id, owner.id)
      assert reloaded.status == "error"
    end

    test "fails if document belongs to other user", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)

      assert {:error, :not_found} =
               Rag.embed_chunks(doc.id, [], other.id, plug: {Req.Test, CohereClient})
    end
  end

  # --- Search ---

  describe "search/4" do
    test "returns search results ordered by distance", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)

      # First, embed some chunks
      embedding1 = List.duplicate(0.1, 1024)
      embedding2 = List.duplicate(0.9, 1024)

      agent = Agent.start_link(fn -> :embed end) |> elem(1)

      Req.Test.stub(CohereClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        response =
          case Agent.get_and_update(agent, fn state ->
                 case state do
                   :embed -> {:embed, :search}
                   :search -> {:search, :search}
                 end
               end) do
            :embed ->
              %{"embeddings" => %{"float" => [embedding1, embedding2]}}

            :search ->
              query_type = decoded["input_type"]
              assert query_type == "search_query"
              %{"embeddings" => %{"float" => [embedding1]}}
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end)

      chunks = [
        %{content: "close chunk", position: 0, token_count: 5},
        %{content: "far chunk", position: 1, token_count: 5}
      ]

      assert {:ok, _} =
               Rag.embed_chunks(doc.id, chunks, owner.id, plug: {Req.Test, CohereClient})

      assert {:ok, results} =
               Rag.search(coll.id, "test query", owner.id, plug: {Req.Test, CohereClient})

      assert length(results) == 2
      assert hd(results).chunk.content == "close chunk"
      assert is_float(hd(results).distance)
    end

    test "respects limit option", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)

      embedding = List.duplicate(0.5, 1024)

      agent = Agent.start_link(fn -> :embed end) |> elem(1)

      Req.Test.stub(CohereClient, fn conn ->
        response =
          case Agent.get_and_update(agent, fn s -> {s, :search} end) do
            :embed ->
              %{"embeddings" => %{"float" => [embedding, embedding, embedding]}}

            :search ->
              %{"embeddings" => %{"float" => [embedding]}}
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end)

      chunks = [
        %{content: "a", position: 0},
        %{content: "b", position: 1},
        %{content: "c", position: 2}
      ]

      {:ok, _} = Rag.embed_chunks(doc.id, chunks, owner.id, plug: {Req.Test, CohereClient})

      assert {:ok, results} =
               Rag.search(coll.id, "query", owner.id,
                 limit: 1,
                 plug: {Req.Test, CohereClient}
               )

      assert length(results) == 1
    end

    test "fails if collection belongs to other user", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      assert {:error, :not_found} = Rag.search(coll.id, "q", other.id)
    end

    test "returns error on embed failure", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)

      Req.Test.stub(CohereClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"message" => "error"}))
      end)

      assert {:error, %{status: 500}} =
               Rag.search(coll.id, "query", owner.id, plug: {Req.Test, CohereClient})
    end
  end

  # --- Rerank ---

  describe "rerank/3" do
    test "reranks chunks by relevance score" do
      chunks = [
        %{chunk: %Chunk{content: "doc a"}, distance: 0.1},
        %{chunk: %Chunk{content: "doc b"}, distance: 0.2},
        %{chunk: %Chunk{content: "doc c"}, distance: 0.3}
      ]

      stub_rerank([
        %{"index" => 2, "relevance_score" => 0.95},
        %{"index" => 0, "relevance_score" => 0.8}
      ])

      assert {:ok, ranked} =
               Rag.rerank("query", chunks, top_n: 2, plug: {Req.Test, CohereClient})

      assert length(ranked) == 2
      assert hd(ranked).chunk.content == "doc c"
      assert hd(ranked).relevance_score == 0.95
    end

    test "returns error on rerank failure" do
      Req.Test.stub(CohereClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"message" => "error"}))
      end)

      assert {:error, _} =
               Rag.rerank("query", [%{chunk: %Chunk{content: "x"}, distance: 0.1}],
                 plug: {Req.Test, CohereClient}
               )
    end
  end

  # --- Search and Rerank ---

  describe "search_and_rerank/4" do
    test "pipelines search into rerank", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)

      embedding = List.duplicate(0.5, 1024)

      agent = Agent.start_link(fn -> 0 end) |> elem(1)

      Req.Test.stub(CohereClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        call_num = Agent.get_and_update(agent, fn n -> {n, n + 1} end)

        response =
          cond do
            # First call: embed chunks
            call_num == 0 ->
              %{"embeddings" => %{"float" => [embedding, embedding]}}

            # Second call: search query embed
            Map.has_key?(decoded, "input_type") ->
              %{"embeddings" => %{"float" => [embedding]}}

            # Third call: rerank
            Map.has_key?(decoded, "query") ->
              %{
                "results" => [
                  %{"index" => 1, "relevance_score" => 0.9},
                  %{"index" => 0, "relevance_score" => 0.7}
                ]
              }
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end)

      chunks = [
        %{content: "first", position: 0},
        %{content: "second", position: 1}
      ]

      {:ok, _} = Rag.embed_chunks(doc.id, chunks, owner.id, plug: {Req.Test, CohereClient})

      assert {:ok, ranked} =
               Rag.search_and_rerank(coll.id, "query", owner.id,
                 search_limit: 50,
                 top_n: 2,
                 plug: {Req.Test, CohereClient}
               )

      assert length(ranked) == 2
      assert hd(ranked).relevance_score == 0.9
    end

    test "fails if collection belongs to other user", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)

      assert {:error, :not_found} =
               Rag.search_and_rerank(coll.id, "q", other.id, plug: {Req.Test, CohereClient})
    end

    test "falls back to top_n search results when rerank fails", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)

      embedding = List.duplicate(0.5, 1024)

      agent = Agent.start_link(fn -> 0 end) |> elem(1)

      Req.Test.stub(CohereClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        call_num = Agent.get_and_update(agent, fn n -> {n, n + 1} end)

        cond do
          # First call: embed chunks
          call_num == 0 ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              200,
              Jason.encode!(%{"embeddings" => %{"float" => [embedding, embedding]}})
            )

          # Second call: search query embed
          Map.has_key?(decoded, "input_type") ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              200,
              Jason.encode!(%{"embeddings" => %{"float" => [embedding]}})
            )

          # Third call: rerank - return error
          Map.has_key?(decoded, "query") ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(500, Jason.encode!(%{"message" => "rerank failed"}))
        end
      end)

      chunks = [
        %{content: "first", position: 0},
        %{content: "second", position: 1}
      ]

      {:ok, _} = Rag.embed_chunks(doc.id, chunks, owner.id, plug: {Req.Test, CohereClient})

      assert {:ok, results} =
               Rag.search_and_rerank(coll.id, "query", owner.id,
                 search_limit: 50,
                 top_n: 2,
                 plug: {Req.Test, CohereClient}
               )

      assert length(results) == 2
      assert Enum.all?(results, fn r -> r.relevance_score == nil end)
    end
  end

  # --- Wiki Sync Helpers ---

  describe "find_or_create_wiki_collection/1" do
    test "creates wiki collection on first call", %{owner: owner} do
      assert {:ok, coll} = Rag.find_or_create_wiki_collection(owner.id)
      assert coll.name == "Wiki"
      assert coll.user_id == owner.id
    end

    test "returns existing wiki collection on second call", %{owner: owner} do
      {:ok, coll1} = Rag.find_or_create_wiki_collection(owner.id)
      {:ok, coll2} = Rag.find_or_create_wiki_collection(owner.id)
      assert coll1.id == coll2.id
    end

    test "creates separate collections per user", %{owner: owner, other: other} do
      {:ok, coll1} = Rag.find_or_create_wiki_collection(owner.id)
      {:ok, coll2} = Rag.find_or_create_wiki_collection(other.id)
      assert coll1.id != coll2.id
    end
  end

  describe "find_or_create_wiki_source/2" do
    test "creates wiki source on first call", %{owner: owner} do
      {:ok, coll} = Rag.find_or_create_wiki_collection(owner.id)
      assert {:ok, source} = Rag.find_or_create_wiki_source(coll.id, owner.id)
      assert source.name == "wiki"
      assert source.collection_id == coll.id
    end

    test "returns existing wiki source on second call", %{owner: owner} do
      {:ok, coll} = Rag.find_or_create_wiki_collection(owner.id)
      {:ok, src1} = Rag.find_or_create_wiki_source(coll.id, owner.id)
      {:ok, src2} = Rag.find_or_create_wiki_source(coll.id, owner.id)
      assert src1.id == src2.id
    end
  end

  describe "find_rag_document_by_wiki_id/2" do
    test "finds document by wiki_document_id metadata", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      wiki_id = Ecto.UUID.generate()

      {:ok, doc} =
        create_document(source.id, owner.id, %{
          metadata: %{"wiki_document_id" => wiki_id}
        })

      assert {:ok, found} = Rag.find_rag_document_by_wiki_id(wiki_id, owner.id)
      assert found.id == doc.id
    end

    test "returns not_found when no match", %{owner: owner} do
      assert {:error, :not_found} =
               Rag.find_rag_document_by_wiki_id(Ecto.UUID.generate(), owner.id)
    end

    test "scoped to user_id", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      wiki_id = Ecto.UUID.generate()

      {:ok, _doc} =
        create_document(source.id, owner.id, %{
          metadata: %{"wiki_document_id" => wiki_id}
        })

      assert {:error, :not_found} = Rag.find_rag_document_by_wiki_id(wiki_id, other.id)
    end

    test "returns doc for user with wiki space ACL", %{owner: owner, other: other} do
      {:ok, space} =
        Liteskill.DataSources.create_document("builtin:wiki", %{title: "Shared"}, owner.id)

      {:ok, _} =
        Liteskill.Authorization.grant_access("wiki_space", space.id, owner.id, other.id, "viewer")

      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      wiki_id = Ecto.UUID.generate()

      {:ok, doc} =
        create_document(source.id, owner.id, %{
          metadata: %{"wiki_document_id" => wiki_id, "wiki_space_id" => space.id}
        })

      assert {:ok, found} = Rag.find_rag_document_by_wiki_id(wiki_id, other.id)
      assert found.id == doc.id
    end

    test "fallback resolves and backfills missing wiki_space_id", %{owner: owner, other: other} do
      {:ok, space} =
        Liteskill.DataSources.create_document("builtin:wiki", %{title: "Shared"}, owner.id)

      {:ok, _} =
        Liteskill.Authorization.grant_access("wiki_space", space.id, owner.id, other.id, "viewer")

      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)

      # RAG doc with wiki_document_id pointing to a real wiki doc in the space,
      # but missing wiki_space_id (pre-backfill scenario)
      {:ok, wiki_child} =
        Liteskill.DataSources.create_child_document(
          "builtin:wiki",
          space.id,
          %{title: "Child Page"},
          owner.id
        )

      {:ok, rag_doc} =
        create_document(source.id, owner.id, %{
          metadata: %{"wiki_document_id" => wiki_child.id}
        })

      # Other user should still find it via fallback
      assert {:ok, found} = Rag.find_rag_document_by_wiki_id(wiki_child.id, other.id)
      assert found.id == rag_doc.id
      # wiki_space_id should be backfilled
      assert found.metadata["wiki_space_id"] == space.id
    end

    test "fallback returns :not_found without ACL access", %{owner: owner, other: other} do
      {:ok, space} =
        Liteskill.DataSources.create_document("builtin:wiki", %{title: "Private"}, owner.id)

      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)

      {:ok, wiki_child} =
        Liteskill.DataSources.create_child_document(
          "builtin:wiki",
          space.id,
          %{title: "Child Page"},
          owner.id
        )

      {:ok, _rag_doc} =
        create_document(source.id, owner.id, %{
          metadata: %{"wiki_document_id" => wiki_child.id}
        })

      # No ACL — should return :not_found
      assert {:error, :not_found} = Rag.find_rag_document_by_wiki_id(wiki_child.id, other.id)
    end
  end

  describe "delete_document_chunks/1" do
    test "deletes all chunks for a document", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)

      emb = List.duplicate(0.1, 1024)
      stub_embed([emb, emb])

      chunks = [
        %{content: "chunk one", position: 0},
        %{content: "chunk two", position: 1}
      ]

      {:ok, _} = Rag.embed_chunks(doc.id, chunks, owner.id, plug: {Req.Test, CohereClient})

      db_chunks = Repo.all(from(c in Chunk, where: c.document_id == ^doc.id))
      assert length(db_chunks) == 2

      assert {:ok, 2} = Rag.delete_document_chunks(doc.id)

      db_chunks = Repo.all(from(c in Chunk, where: c.document_id == ^doc.id))
      assert db_chunks == []
    end

    test "returns 0 when no chunks exist" do
      assert {:ok, 0} = Rag.delete_document_chunks(Ecto.UUID.generate())
    end
  end

  # --- Augment Context ---

  describe "augment_context/3" do
    test "returns results with preloaded document.source", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id, %{name: "test-source"})
      {:ok, doc} = create_document(source.id, owner.id, %{title: "Test Doc"})

      embedding = List.duplicate(0.1, 1024)

      agent = Agent.start_link(fn -> :embed end) |> elem(1)

      Req.Test.stub(CohereClient, fn conn ->
        response =
          case Agent.get_and_update(agent, fn state ->
                 case state do
                   :embed -> {:embed, :query}
                   :query -> {:query, :query}
                 end
               end) do
            :embed -> %{"embeddings" => %{"float" => [embedding]}}
            :query -> %{"embeddings" => %{"float" => [embedding]}}
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end)

      chunks = [%{content: "hello world", position: 0}]
      assert {:ok, _} = Rag.embed_chunks(doc.id, chunks, owner.id, plug: {Req.Test, CohereClient})

      assert {:ok, results} =
               Rag.augment_context("hello", owner.id, plug: {Req.Test, CohereClient})

      assert results != []
      first = hd(results)
      assert first.chunk.document.title == "Test Doc"
      assert first.chunk.document.source.name == "test-source"
      assert first.relevance_score == nil
    end

    test "returns empty list when user has no chunks", %{owner: owner} do
      stub_embed([[0.1] |> List.duplicate(1024) |> List.flatten()])

      assert {:ok, []} =
               Rag.augment_context("hello", owner.id, plug: {Req.Test, CohereClient})
    end

    test "returns empty list on embed failure", %{owner: owner} do
      Req.Test.stub(CohereClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"message" => "error"}))
      end)

      assert {:ok, []} =
               Rag.augment_context("hello", owner.id, plug: {Req.Test, CohereClient})
    end

    test "reranks when 40+ results and returns ranked", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)

      embedding = List.duplicate(0.1, 1024)
      chunk_count = 45

      agent = Agent.start_link(fn -> 0 end) |> elem(1)

      Req.Test.stub(CohereClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        call_num = Agent.get_and_update(agent, fn n -> {n, n + 1} end)

        cond do
          # First call: embed chunks
          call_num == 0 ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              200,
              Jason.encode!(%{
                "embeddings" => %{"float" => List.duplicate(embedding, chunk_count)}
              })
            )

          # Second call: augment_context query embed
          Map.has_key?(decoded, "input_type") ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              200,
              Jason.encode!(%{"embeddings" => %{"float" => [embedding]}})
            )

          # Third call: rerank
          Map.has_key?(decoded, "query") ->
            results =
              Enum.map(0..39, fn i ->
                %{"index" => i, "relevance_score" => 1.0 - i * 0.01}
              end)

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(%{"results" => results}))
        end
      end)

      chunks = Enum.map(0..(chunk_count - 1), fn i -> %{content: "chunk #{i}", position: i} end)

      {:ok, _} = Rag.embed_chunks(doc.id, chunks, owner.id, plug: {Req.Test, CohereClient})

      assert {:ok, results} =
               Rag.augment_context("test", owner.id, plug: {Req.Test, CohereClient})

      assert length(results) == 40
      assert hd(results).relevance_score != nil
    end

    test "falls back when rerank fails with 40+ results", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)

      embedding = List.duplicate(0.1, 1024)
      chunk_count = 45

      agent = Agent.start_link(fn -> 0 end) |> elem(1)

      Req.Test.stub(CohereClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        call_num = Agent.get_and_update(agent, fn n -> {n, n + 1} end)

        cond do
          call_num == 0 ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              200,
              Jason.encode!(%{
                "embeddings" => %{"float" => List.duplicate(embedding, chunk_count)}
              })
            )

          Map.has_key?(decoded, "input_type") ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              200,
              Jason.encode!(%{"embeddings" => %{"float" => [embedding]}})
            )

          Map.has_key?(decoded, "query") ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(500, Jason.encode!(%{"message" => "rerank error"}))
        end
      end)

      chunks = Enum.map(0..(chunk_count - 1), fn i -> %{content: "chunk #{i}", position: i} end)

      {:ok, _} = Rag.embed_chunks(doc.id, chunks, owner.id, plug: {Req.Test, CohereClient})

      assert {:ok, results} =
               Rag.augment_context("test", owner.id, plug: {Req.Test, CohereClient})

      assert length(results) == 40
      assert Enum.all?(results, fn r -> r.relevance_score == nil end)
    end

    test "searches across multiple collections", %{owner: owner} do
      {:ok, coll1} = create_collection(owner.id, %{name: "Collection A"})
      {:ok, source1} = create_source(coll1.id, owner.id, %{name: "src-a"})
      {:ok, doc1} = create_document(source1.id, owner.id, %{title: "Doc A"})

      {:ok, coll2} = create_collection(owner.id, %{name: "Collection B"})
      {:ok, source2} = create_source(coll2.id, owner.id, %{name: "src-b"})
      {:ok, doc2} = create_document(source2.id, owner.id, %{title: "Doc B"})

      embedding = List.duplicate(0.1, 1024)
      call_count = Agent.start_link(fn -> 0 end) |> elem(1)

      Req.Test.stub(CohereClient, fn conn ->
        n = Agent.get_and_update(call_count, fn c -> {c, c + 1} end)

        response =
          case n do
            0 -> %{"embeddings" => %{"float" => [embedding]}}
            1 -> %{"embeddings" => %{"float" => [embedding]}}
            _ -> %{"embeddings" => %{"float" => [embedding]}}
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end)

      chunks1 = [%{content: "chunk from A", position: 0}]

      assert {:ok, _} =
               Rag.embed_chunks(doc1.id, chunks1, owner.id, plug: {Req.Test, CohereClient})

      chunks2 = [%{content: "chunk from B", position: 0}]

      assert {:ok, _} =
               Rag.embed_chunks(doc2.id, chunks2, owner.id, plug: {Req.Test, CohereClient})

      assert {:ok, results} =
               Rag.augment_context("test", owner.id, plug: {Req.Test, CohereClient})

      contents = Enum.map(results, & &1.chunk.content)
      assert "chunk from A" in contents
      assert "chunk from B" in contents
    end
  end

  # --- Wiki Space ACL in vector_search_all ---

  describe "augment_context with wiki space ACL" do
    test "returns chunks from shared wiki spaces", %{owner: owner, other: other} do
      # Owner creates a wiki space
      {:ok, space} =
        Liteskill.DataSources.create_document("builtin:wiki", %{title: "Shared Space"}, owner.id)

      # Grant viewer access to other user
      {:ok, _} =
        Liteskill.Authorization.grant_access("wiki_space", space.id, owner.id, other.id, "viewer")

      # Create RAG document with wiki_space_id metadata (simulating wiki sync)
      {:ok, coll} = create_collection(owner.id, %{name: "Wiki"})
      {:ok, source} = create_source(coll.id, owner.id, %{name: "wiki"})

      {:ok, rag_doc} =
        create_document(source.id, owner.id, %{
          title: "Shared Page",
          metadata: %{"wiki_document_id" => Ecto.UUID.generate(), "wiki_space_id" => space.id}
        })

      embedding = List.duplicate(0.1, 1024)

      agent = Agent.start_link(fn -> :embed end) |> elem(1)

      Req.Test.stub(CohereClient, fn conn ->
        response =
          case Agent.get_and_update(agent, fn state ->
                 case state do
                   :embed -> {:embed, :query}
                   :query -> {:query, :query}
                 end
               end) do
            :embed -> %{"embeddings" => %{"float" => [embedding]}}
            :query -> %{"embeddings" => %{"float" => [embedding]}}
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end)

      chunks = [%{content: "shared wiki content", position: 0}]

      assert {:ok, _} =
               Rag.embed_chunks(rag_doc.id, chunks, owner.id, plug: {Req.Test, CohereClient})

      # Other user (with ACL) can see chunks via augment_context
      assert {:ok, results} =
               Rag.augment_context("wiki", other.id, plug: {Req.Test, CohereClient})

      assert results != []
      assert hd(results).chunk.content == "shared wiki content"
    end

    test "does not return wiki chunks from spaces without ACL", %{owner: owner, other: other} do
      # Owner creates a wiki space but does NOT share it
      {:ok, space} =
        Liteskill.DataSources.create_document("builtin:wiki", %{title: "Private Space"}, owner.id)

      {:ok, coll} = create_collection(owner.id, %{name: "Wiki"})
      {:ok, source} = create_source(coll.id, owner.id, %{name: "wiki"})

      {:ok, rag_doc} =
        create_document(source.id, owner.id, %{
          title: "Private Page",
          metadata: %{"wiki_document_id" => Ecto.UUID.generate(), "wiki_space_id" => space.id}
        })

      embedding = List.duplicate(0.1, 1024)

      agent = Agent.start_link(fn -> :embed end) |> elem(1)

      Req.Test.stub(CohereClient, fn conn ->
        response =
          case Agent.get_and_update(agent, fn state ->
                 case state do
                   :embed -> {:embed, :query}
                   :query -> {:query, :query}
                 end
               end) do
            :embed -> %{"embeddings" => %{"float" => [embedding]}}
            :query -> %{"embeddings" => %{"float" => [embedding]}}
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end)

      chunks = [%{content: "private wiki content", position: 0}]

      assert {:ok, _} =
               Rag.embed_chunks(rag_doc.id, chunks, owner.id, plug: {Req.Test, CohereClient})

      # Other user (no ACL) should NOT see chunks
      assert {:ok, results} =
               Rag.augment_context("wiki", other.id, plug: {Req.Test, CohereClient})

      assert results == []
    end
  end

  # --- SHA256 Hashing ---

  describe "SHA256 content hashing" do
    test "create_document sets content_hash when content is provided", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)

      {:ok, doc} =
        create_document(source.id, owner.id, %{content: "hello world"})

      expected_hash =
        :crypto.hash(:sha256, "hello world") |> Base.encode16(case: :lower)

      assert doc.content_hash == expected_hash
    end

    test "create_document leaves content_hash nil when no content", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)

      {:ok, doc} = create_document(source.id, owner.id)
      assert doc.content_hash == nil
    end

    test "embed_chunks sets content_hash on chunks", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)

      stub_embed([List.duplicate(0.1, 1024)])
      chunks = [%{content: "chunk content", position: 0}]

      assert {:ok, _} =
               Rag.embed_chunks(doc.id, chunks, owner.id, plug: {Req.Test, CohereClient})

      db_chunks = Chunk |> where([c], c.document_id == ^doc.id) |> Repo.all()
      assert length(db_chunks) == 1

      expected_hash =
        :crypto.hash(:sha256, "chunk content") |> Base.encode16(case: :lower)

      assert hd(db_chunks).content_hash == expected_hash
    end
  end

  # --- Embedding Request Logging ---

  describe "embedding request logging" do
    test "embed_chunks logs embedding request when user_id provided", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)

      stub_embed([List.duplicate(0.1, 1024)])
      chunks = [%{content: "logged chunk", position: 0}]

      assert {:ok, _} =
               Rag.embed_chunks(doc.id, chunks, owner.id, plug: {Req.Test, CohereClient})

      alias Liteskill.Rag.EmbeddingRequest

      requests =
        EmbeddingRequest
        |> where([e], e.user_id == ^owner.id)
        |> Repo.all()

      assert requests != []

      embed_req = Enum.find(requests, &(&1.request_type == "embed"))
      assert embed_req != nil
      assert embed_req.status == "success"
      assert embed_req.model_id == "us.cohere.embed-v4:0"
      assert embed_req.input_count == 1
      assert embed_req.latency_ms >= 0
    end
  end

  # --- Source Document Lookup ---

  describe "get_rag_document_for_source_doc/2" do
    test "finds RAG document linked via wiki_document_id metadata", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      wiki_doc_id = Ecto.UUID.generate()

      {:ok, rag_doc} =
        create_document(source.id, owner.id, %{
          title: "Wiki Doc",
          metadata: %{"wiki_document_id" => wiki_doc_id}
        })

      assert {:ok, found} = Rag.get_rag_document_for_source_doc(wiki_doc_id, owner.id)
      assert found.id == rag_doc.id
    end

    test "returns :not_found when no matching RAG document", %{owner: owner} do
      assert {:error, :not_found} =
               Rag.get_rag_document_for_source_doc(Ecto.UUID.generate(), owner.id)
    end

    test "returns :not_found for another user's RAG document", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(other.id)
      {:ok, source} = create_source(coll.id, other.id)
      wiki_doc_id = Ecto.UUID.generate()

      {:ok, _} =
        create_document(source.id, other.id, %{
          title: "Other Doc",
          metadata: %{"wiki_document_id" => wiki_doc_id}
        })

      assert {:error, :not_found} = Rag.get_rag_document_for_source_doc(wiki_doc_id, owner.id)
    end

    test "returns doc for user with wiki space ACL via wiki_document_id", %{
      owner: owner,
      other: other
    } do
      {:ok, space} =
        Liteskill.DataSources.create_document("builtin:wiki", %{title: "Shared"}, owner.id)

      {:ok, _} =
        Liteskill.Authorization.grant_access("wiki_space", space.id, owner.id, other.id, "viewer")

      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      wiki_doc_id = Ecto.UUID.generate()

      {:ok, doc} =
        create_document(source.id, owner.id, %{
          title: "Shared Wiki Doc",
          metadata: %{"wiki_document_id" => wiki_doc_id, "wiki_space_id" => space.id}
        })

      assert {:ok, found} = Rag.get_rag_document_for_source_doc(wiki_doc_id, other.id)
      assert found.id == doc.id
    end

    test "returns doc for user with wiki space ACL via source_document_id", %{
      owner: owner,
      other: other
    } do
      {:ok, space} =
        Liteskill.DataSources.create_document("builtin:wiki", %{title: "Shared"}, owner.id)

      {:ok, _} =
        Liteskill.Authorization.grant_access("wiki_space", space.id, owner.id, other.id, "viewer")

      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      source_doc_id = Ecto.UUID.generate()

      {:ok, doc} =
        create_document(source.id, owner.id, %{
          title: "Shared Source Doc",
          metadata: %{"source_document_id" => source_doc_id, "wiki_space_id" => space.id}
        })

      assert {:ok, found} = Rag.get_rag_document_for_source_doc(source_doc_id, other.id)
      assert found.id == doc.id
    end

    test "fallback resolves missing wiki_space_id via wiki_document_id", %{
      owner: owner,
      other: other
    } do
      {:ok, space} =
        Liteskill.DataSources.create_document("builtin:wiki", %{title: "Shared"}, owner.id)

      {:ok, _} =
        Liteskill.Authorization.grant_access("wiki_space", space.id, owner.id, other.id, "viewer")

      {:ok, wiki_child} =
        Liteskill.DataSources.create_child_document(
          "builtin:wiki",
          space.id,
          %{title: "Child Page"},
          owner.id
        )

      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)

      {:ok, rag_doc} =
        create_document(source.id, owner.id, %{
          title: "Missing Space ID",
          metadata: %{"wiki_document_id" => wiki_child.id}
        })

      assert {:ok, found} = Rag.get_rag_document_for_source_doc(wiki_child.id, other.id)
      assert found.id == rag_doc.id
      assert found.metadata["wiki_space_id"] == space.id
    end
  end

  describe "find_rag_document_by_source_doc_id/2" do
    test "returns doc for user with wiki space ACL", %{owner: owner, other: other} do
      {:ok, space} =
        Liteskill.DataSources.create_document("builtin:wiki", %{title: "Shared"}, owner.id)

      {:ok, _} =
        Liteskill.Authorization.grant_access("wiki_space", space.id, owner.id, other.id, "viewer")

      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      source_doc_id = Ecto.UUID.generate()

      {:ok, doc} =
        create_document(source.id, owner.id, %{
          title: "Shared Doc",
          metadata: %{"source_document_id" => source_doc_id, "wiki_space_id" => space.id}
        })

      assert {:ok, found} = Rag.find_rag_document_by_source_doc_id(source_doc_id, other.id)
      assert found.id == doc.id
    end

    test "returns :not_found without wiki space ACL", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      source_doc_id = Ecto.UUID.generate()

      {:ok, _} =
        create_document(source.id, owner.id, %{
          title: "Private Doc",
          metadata: %{"source_document_id" => source_doc_id}
        })

      assert {:error, :not_found} =
               Rag.find_rag_document_by_source_doc_id(source_doc_id, other.id)
    end
  end

  describe "list_chunks_for_document/1" do
    test "returns chunks ordered by position", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id, %{title: "Chunked"})

      for pos <- [2, 0, 1] do
        %Chunk{}
        |> Chunk.changeset(%{
          content: "Chunk #{pos}",
          position: pos,
          document_id: doc.id,
          token_count: 10 + pos,
          content_hash: "hash_#{pos}"
        })
        |> Liteskill.Repo.insert!()
      end

      chunks = Rag.list_chunks_for_document(doc.id)
      assert length(chunks) == 3
      assert Enum.map(chunks, & &1.position) == [0, 1, 2]
      assert Enum.map(chunks, & &1.content_hash) == ["hash_0", "hash_1", "hash_2"]
    end

    test "returns empty list when no chunks", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id, %{title: "Empty"})

      assert Rag.list_chunks_for_document(doc.id) == []
    end
  end

  # --- Re-embedding support ---

  describe "total_chunk_count/0" do
    test "returns 0 when no chunks", %{owner: _owner} do
      assert Rag.total_chunk_count() == 0
    end

    test "returns correct count across documents", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc1} = create_document(source.id, owner.id, %{title: "Doc1"})
      {:ok, doc2} = create_document(source.id, owner.id, %{title: "Doc2"})

      for pos <- 0..2 do
        insert_chunk(doc1.id, pos)
      end

      insert_chunk(doc2.id, 0)

      assert Rag.total_chunk_count() == 4
    end
  end

  describe "clear_all_embeddings/0" do
    test "clears embeddings and resets document statuses", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id, %{title: "Embedded"})

      embedding = Pgvector.new(List.duplicate(0.1, 1024))

      chunk =
        insert_chunk(doc.id, 0, embedding: embedding)

      doc
      |> Document.changeset(%{status: "embedded", chunk_count: 1})
      |> Repo.update!()

      assert {:ok, %{chunks_cleared: 1, documents_reset: 1}} = Rag.clear_all_embeddings()

      updated_chunk = Repo.get!(Chunk, chunk.id)
      assert updated_chunk.embedding == nil

      updated_doc = Repo.get!(Document, doc.id)
      assert updated_doc.status == "pending"
    end

    test "returns zeros when nothing to clear", %{owner: _owner} do
      assert {:ok, %{chunks_cleared: 0, documents_reset: 0}} = Rag.clear_all_embeddings()
    end

    test "only clears chunks that have embeddings", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id, %{title: "Mixed"})

      embedding = Pgvector.new(List.duplicate(0.1, 1024))
      insert_chunk(doc.id, 0, embedding: embedding)
      insert_chunk(doc.id, 1)

      assert {:ok, %{chunks_cleared: 1}} = Rag.clear_all_embeddings()
    end

    test "only resets documents with embedded status", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)

      {:ok, doc1} = create_document(source.id, owner.id, %{title: "Embedded"})

      doc1
      |> Document.changeset(%{status: "embedded"})
      |> Repo.update!()

      {:ok, _doc2} = create_document(source.id, owner.id, %{title: "Pending"})

      {:ok, doc3} = create_document(source.id, owner.id, %{title: "Error"})

      doc3
      |> Document.changeset(%{status: "error"})
      |> Repo.update!()

      assert {:ok, %{documents_reset: 1}} = Rag.clear_all_embeddings()
    end
  end

  describe "list_documents_for_reembedding/2" do
    test "returns pending documents with chunks", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)

      {:ok, doc1} = create_document(source.id, owner.id, %{title: "Pending With Chunks"})

      doc1
      |> Document.changeset(%{chunk_count: 3})
      |> Repo.update!()

      insert_chunk(doc1.id, 0)

      # Pending but no chunks — should NOT appear
      {:ok, _doc2} = create_document(source.id, owner.id, %{title: "Pending No Chunks"})

      # Embedded — should NOT appear
      {:ok, doc3} = create_document(source.id, owner.id, %{title: "Already Embedded"})

      doc3
      |> Document.changeset(%{status: "embedded", chunk_count: 1})
      |> Repo.update!()

      results = Rag.list_documents_for_reembedding(10, 0)
      assert length(results) == 1
      assert hd(results).id == doc1.id
    end

    test "respects limit and offset", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)

      for i <- 1..5 do
        {:ok, doc} = create_document(source.id, owner.id, %{title: "Doc #{i}"})

        doc
        |> Document.changeset(%{chunk_count: 1})
        |> Repo.update!()

        insert_chunk(doc.id, 0)
      end

      all = Rag.list_documents_for_reembedding(100, 0)
      total = length(all)

      first_batch = Rag.list_documents_for_reembedding(2, 0)
      assert length(first_batch) == 2

      second_batch = Rag.list_documents_for_reembedding(2, 2)
      assert length(second_batch) == 2

      # first and second batch should not overlap
      first_ids = MapSet.new(first_batch, & &1.id)
      second_ids = MapSet.new(second_batch, & &1.id)
      assert MapSet.disjoint?(first_ids, second_ids)

      remaining = Rag.list_documents_for_reembedding(100, 4)
      assert length(remaining) == total - 4
    end

    test "returns empty list when no pending documents", %{owner: _owner} do
      assert Rag.list_documents_for_reembedding(10, 0) == []
    end
  end

  defp insert_chunk(document_id, position, opts \\ []) do
    attrs = %{
      content: "Chunk #{position}",
      position: position,
      document_id: document_id,
      token_count: 10,
      content_hash: "hash_#{position}_#{System.unique_integer([:positive])}"
    }

    attrs =
      case Keyword.get(opts, :embedding) do
        nil -> attrs
        emb -> Map.put(attrs, :embedding, emb)
      end

    %Chunk{}
    |> Chunk.changeset(attrs)
    |> Repo.insert!()
  end
end
