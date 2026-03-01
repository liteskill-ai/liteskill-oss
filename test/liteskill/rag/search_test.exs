defmodule Liteskill.Rag.SearchTest do
  use Liteskill.DataCase, async: true

  import Liteskill.RagTestHelpers
  import Liteskill.RetryTestHelpers

  alias Liteskill.Rag
  alias Liteskill.Rag.Chunk
  alias Liteskill.Rag.CohereClient

  setup :setup_users

  describe "search/4" do
    test "returns search results ordered by distance", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)

      # First, embed some chunks
      embedding1 = List.duplicate(0.1, 1024)
      embedding2 = List.duplicate(0.9, 1024)

      agent = fn -> :embed end |> Agent.start_link() |> elem(1)

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

      agent = fn -> :embed end |> Agent.start_link() |> elem(1)

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
               Rag.rerank("query", [%{chunk: %Chunk{content: "x"}, distance: 0.1}], plug: {Req.Test, CohereClient})
    end
  end

  # --- Search and Rerank ---

  describe "search_and_rerank/4" do
    test "pipelines search into rerank", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)

      embedding = List.duplicate(0.5, 1024)

      agent = retry_counter()

      Req.Test.stub(CohereClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        call_num = next_count(agent)

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

      agent = retry_counter()

      Req.Test.stub(CohereClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        call_num = next_count(agent)

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

  # --- Augment Context ---

  describe "augment_context/3" do
    test "returns results with preloaded document.source", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id, %{name: "test-source"})
      {:ok, doc} = create_document(source.id, owner.id, %{title: "Test Doc"})

      embedding = List.duplicate(0.1, 1024)

      agent = fn -> :embed end |> Agent.start_link() |> elem(1)

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

      agent = retry_counter()

      Req.Test.stub(CohereClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        call_num = next_count(agent)

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
      assert hd(results).relevance_score
    end

    test "falls back when rerank fails with 40+ results", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)

      embedding = List.duplicate(0.1, 1024)
      chunk_count = 45

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
      call_count = retry_counter()

      Req.Test.stub(CohereClient, fn conn ->
        n = next_count(call_count)

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

      agent = fn -> :embed end |> Agent.start_link() |> elem(1)

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

      agent = fn -> :embed end |> Agent.start_link() |> elem(1)

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

  # --- Embedding Request Logging ---

  describe "embedding request logging" do
    test "embed_chunks logs embedding request when user_id provided", %{owner: owner} do
      alias Liteskill.Rag.EmbeddingRequest

      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)

      stub_embed([List.duplicate(0.1, 1024)])
      chunks = [%{content: "logged chunk", position: 0}]

      assert {:ok, _} =
               Rag.embed_chunks(doc.id, chunks, owner.id, plug: {Req.Test, CohereClient})

      requests =
        EmbeddingRequest
        |> where([e], e.user_id == ^owner.id)
        |> Repo.all()

      assert requests != []

      embed_req = Enum.find(requests, &(&1.request_type == "embed"))
      assert embed_req
      assert embed_req.status == "success"
      assert embed_req.model_id == "us.cohere.embed-v4:0"
      assert embed_req.input_count == 1
      assert embed_req.latency_ms >= 0
    end
  end
end
