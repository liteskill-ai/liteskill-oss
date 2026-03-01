defmodule Liteskill.BuiltinTools.DeepResearchTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.BuiltinTools.DeepResearch
  alias Liteskill.Rag
  alias Liteskill.Rag.CohereClient

  setup do
    {:ok, user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "dr-#{System.unique_integer([:positive])}@example.com",
        name: "Deep Research User",
        oidc_sub: "dr-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{user: user}
  end

  defp create_collection(user_id, attrs) do
    Rag.create_collection(Map.merge(%{name: "Test Collection"}, attrs), user_id)
  end

  defp create_source(collection_id, user_id, attrs \\ %{}) do
    Rag.create_source(collection_id, Map.merge(%{name: "Test Source"}, attrs), user_id)
  end

  defp create_document(source_id, user_id, attrs \\ %{}) do
    Rag.create_document(source_id, Map.merge(%{title: "Test Document"}, attrs), user_id)
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

  defp decode_content(%{"content" => [%{"text" => json}]}) do
    Jason.decode!(json)
  end

  # --- Metadata ---

  describe "metadata" do
    test "id/0" do
      assert DeepResearch.id() == "deep_research"
    end

    test "name/0" do
      assert DeepResearch.name() == "Deep Research"
    end

    test "description/0" do
      assert DeepResearch.description() == "Semantic search across knowledge base collections"
    end

    test "list_tools/0 returns two tools" do
      tools = DeepResearch.list_tools()
      assert length(tools) == 2
      names = Enum.map(tools, & &1["name"])
      assert "deep_research__query_sources" in names
      assert "deep_research__query_vector" in names
    end

    test "list_tools/0 tools have inputSchema" do
      tools = DeepResearch.list_tools()

      for tool <- tools do
        assert is_map(tool["inputSchema"])
        assert tool["inputSchema"]["type"] == "object"
      end
    end
  end

  # --- query_sources ---

  describe "query_sources" do
    test "lists collections with document counts", %{user: user} do
      {:ok, coll} = create_collection(user.id, %{name: "Research KB", description: "My KB"})
      {:ok, source} = create_source(coll.id, user.id)
      {:ok, _doc} = create_document(source.id, user.id, %{title: "Doc 1"})
      {:ok, _doc2} = create_document(source.id, user.id, %{title: "Doc 2"})

      ctx = [user_id: user.id]
      {:ok, result} = DeepResearch.call_tool("deep_research__query_sources", %{}, ctx)
      data = decode_content(result)

      assert is_list(data["collections"])
      assert length(data["collections"]) == 1

      entry = hd(data["collections"])
      assert entry["id"] == coll.id
      assert entry["name"] == "Research KB"
      assert entry["description"] == "My KB"
      assert entry["document_count"] == 2
    end

    test "returns empty collections list when user has none", %{user: user} do
      ctx = [user_id: user.id]
      {:ok, result} = DeepResearch.call_tool("deep_research__query_sources", %{}, ctx)
      data = decode_content(result)

      assert data["collections"] == []
    end

    test "returns multiple collections", %{user: user} do
      {:ok, coll_a} = create_collection(user.id, %{name: "Alpha"})
      {:ok, coll_b} = create_collection(user.id, %{name: "Beta"})
      {:ok, src_a} = create_source(coll_a.id, user.id)
      {:ok, _} = create_document(src_a.id, user.id)

      ctx = [user_id: user.id]
      {:ok, result} = DeepResearch.call_tool("deep_research__query_sources", %{}, ctx)
      data = decode_content(result)

      assert length(data["collections"]) == 2
      names = Enum.map(data["collections"], & &1["name"])
      assert "Alpha" in names
      assert "Beta" in names

      alpha = Enum.find(data["collections"], &(&1["id"] == coll_a.id))
      beta = Enum.find(data["collections"], &(&1["id"] == coll_b.id))
      assert alpha["document_count"] == 1
      assert beta["document_count"] == 0
    end
  end

  # --- query_vector (all collections) ---

  describe "query_vector all collections" do
    test "searches all accessible collections", %{user: user} do
      {:ok, coll} = create_collection(user.id, %{name: "KB"})
      {:ok, source} = create_source(coll.id, user.id, %{name: "src"})
      {:ok, doc} = create_document(source.id, user.id, %{title: "My Doc"})

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

      chunks = [%{content: "relevant content", position: 0}]
      {:ok, _} = Rag.embed_chunks(doc.id, chunks, user.id, plug: {Req.Test, CohereClient})

      ctx = [user_id: user.id, plug: {Req.Test, CohereClient}]

      {:ok, result} =
        DeepResearch.call_tool("deep_research__query_vector", %{"query" => "relevant"}, ctx)

      data = decode_content(result)

      assert data["total"] >= 1
      first = hd(data["results"])
      assert first["content"] == "relevant content"
      assert first["document_title"] == "My Doc"
      assert first["source_name"] == "src"
      assert first["collection_name"] == "KB"
    end

    test "returns empty results when no chunks exist", %{user: user} do
      stub_embed([List.duplicate(0.1, 1024)])

      ctx = [user_id: user.id, plug: {Req.Test, CohereClient}]

      {:ok, result} =
        DeepResearch.call_tool("deep_research__query_vector", %{"query" => "anything"}, ctx)

      data = decode_content(result)
      assert data["results"] == []
      assert data["total"] == 0
    end
  end

  # --- query_vector (filtered) ---

  describe "query_vector filtered collections" do
    test "searches specific collection by ID", %{user: user} do
      {:ok, coll} = create_collection(user.id, %{name: "Filtered"})
      {:ok, source} = create_source(coll.id, user.id, %{name: "fsrc"})
      {:ok, doc} = create_document(source.id, user.id, %{title: "Filtered Doc"})

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

      chunks = [%{content: "filtered content", position: 0}]
      {:ok, _} = Rag.embed_chunks(doc.id, chunks, user.id, plug: {Req.Test, CohereClient})

      ctx = [user_id: user.id, plug: {Req.Test, CohereClient}]

      {:ok, result} =
        DeepResearch.call_tool(
          "deep_research__query_vector",
          %{"query" => "filtered", "collection_ids" => [coll.id]},
          ctx
        )

      data = decode_content(result)
      assert data["total"] >= 1
      first = hd(data["results"])
      assert first["content"] == "filtered content"
      assert first["document_title"] == "Filtered Doc"
      assert first["collection_name"] == "Filtered"
    end

    test "ignores non-existent collection IDs gracefully", %{user: user} do
      stub_embed([List.duplicate(0.1, 1024)])

      ctx = [user_id: user.id, plug: {Req.Test, CohereClient}]

      {:ok, result} =
        DeepResearch.call_tool(
          "deep_research__query_vector",
          %{"query" => "test", "collection_ids" => [Ecto.UUID.generate()]},
          ctx
        )

      data = decode_content(result)
      assert data["results"] == []
      assert data["total"] == 0
    end
  end

  # --- Error cases ---

  describe "error cases" do
    test "query_vector missing query returns error", %{user: user} do
      ctx = [user_id: user.id]
      {:ok, result} = DeepResearch.call_tool("deep_research__query_vector", %{}, ctx)
      data = decode_content(result)
      assert data["error"] == "Missing required field: query"
    end

    test "query_vector empty query returns error", %{user: user} do
      ctx = [user_id: user.id]
      {:ok, result} = DeepResearch.call_tool("deep_research__query_vector", %{"query" => ""}, ctx)
      data = decode_content(result)
      assert data["error"] == "query must be a non-empty string"
    end

    test "unknown tool returns error", %{user: user} do
      ctx = [user_id: user.id]
      {:ok, result} = DeepResearch.call_tool("deep_research__bogus", %{}, ctx)
      data = decode_content(result)
      assert data["error"] == "Unknown tool: deep_research__bogus"
    end
  end
end
