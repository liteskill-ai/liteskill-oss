defmodule Liteskill.Rag.CollectionsTest do
  use Liteskill.DataCase, async: true

  import Liteskill.RagTestHelpers
  import Liteskill.RetryTestHelpers

  alias Liteskill.Rag
  alias Liteskill.Rag.CohereClient
  alias Liteskill.Rag.Collection

  setup :setup_users

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
      agent = fn -> :embed end |> Agent.start_link() |> elem(1)

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
      agent = fn -> :embed end |> Agent.start_link() |> elem(1)

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
      agent = fn -> :embed end |> Agent.start_link() |> elem(1)

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
      agent = retry_counter()

      Req.Test.stub(CohereClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        call_num = next_count(agent)

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
end
