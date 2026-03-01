defmodule Liteskill.BuiltinTools.DeepResearch do
  @moduledoc """
  Built-in tool suite for semantic search across RAG knowledge base collections.
  """

  @behaviour Liteskill.BuiltinTools

  alias Liteskill.Rag
  alias Liteskill.Repo

  @impl true
  def id, do: "deep_research"

  @impl true
  def name, do: "Deep Research"

  @impl true
  def description, do: "Semantic search across knowledge base collections"

  @impl true
  def list_tools do
    [
      %{
        "name" => "deep_research__query_sources",
        "description" =>
          "List available knowledge base collections with document counts. " <>
            "Use this to discover what data sources are available before searching.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{},
          "required" => []
        }
      },
      %{
        "name" => "deep_research__query_vector",
        "description" =>
          "Perform semantic vector search across knowledge base collections. " <>
            "Returns the most relevant document chunks matching the query. " <>
            "Optionally filter to specific collections by ID.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "query" => %{
              "type" => "string",
              "description" => "The search query to find relevant content"
            },
            "collection_ids" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" =>
                "Optional list of collection IDs to search. " <>
                  "If omitted, searches all accessible collections."
            },
            "top_n" => %{
              "type" => "integer",
              "description" => "Maximum number of results to return (default: 10)"
            }
          },
          "required" => ["query"]
        }
      }
    ]
  end

  @impl true
  def call_tool(tool_name, input, context) do
    user_id = Keyword.fetch!(context, :user_id)
    plug_opts = Keyword.take(context, [:plug])

    case_result =
      case tool_name do
        "deep_research__query_sources" -> do_query_sources(user_id)
        "deep_research__query_vector" -> do_query_vector(user_id, input, plug_opts)
        _ -> {:error, "Unknown tool: #{tool_name}"}
      end

    wrap_result(case_result)
  end

  # --- query_sources ---

  defp do_query_sources(user_id) do
    collections = Rag.list_accessible_collections(user_id)

    entries =
      Enum.map(collections, fn coll ->
        %{
          "id" => coll.id,
          "name" => coll.name,
          "description" => coll.description,
          "document_count" => Rag.collection_document_count(coll.id)
        }
      end)

    {:ok, %{"collections" => entries}}
  end

  # --- query_vector ---

  defp do_query_vector(_user_id, %{"query" => query}, _plug_opts) when not is_binary(query) or byte_size(query) == 0 do
    {:error, "query must be a non-empty string"}
  end

  defp do_query_vector(user_id, %{"query" => query} = input, plug_opts) do
    collection_ids = Map.get(input, "collection_ids", [])
    top_n = Map.get(input, "top_n", 10)

    results =
      if collection_ids == [] do
        search_all(query, user_id, plug_opts)
      else
        search_collections(collection_ids, query, user_id, top_n, plug_opts)
      end

    entries = Enum.map(results, &format_result/1)
    {:ok, %{"results" => entries, "total" => length(entries)}}
  end

  defp do_query_vector(_user_id, _input, _plug_opts) do
    {:error, "Missing required field: query"}
  end

  defp search_all(query, user_id, plug_opts) do
    {:ok, results} = Rag.augment_context(query, user_id, plug_opts)
    chunks = Enum.map(results, & &1.chunk)
    preloaded = Repo.preload(chunks, document: [source: :collection])
    Enum.zip_with(results, preloaded, fn r, c -> %{r | chunk: c} end)
  end

  defp search_collections(collection_ids, query, user_id, top_n, plug_opts) do
    opts = [{:top_n, top_n}] ++ plug_opts

    collection_ids
    |> Enum.flat_map(fn coll_id ->
      case Rag.search_accessible(coll_id, query, user_id, opts) do
        {:ok, results} -> results
        {:error, _} -> []
      end
    end)
    |> Enum.sort_by(fn r -> r[:relevance_score] || 1.0 end, :desc)
    |> Enum.take(top_n)
    |> then(fn results ->
      chunks = Enum.map(results, & &1.chunk)
      preloaded = Repo.preload(chunks, document: [source: :collection])
      Enum.zip_with(results, preloaded, fn r, c -> %{r | chunk: c} end)
    end)
  end

  defp format_result(result) do
    chunk = result.chunk
    doc = if Ecto.assoc_loaded?(chunk.document), do: chunk.document
    source = if doc && Ecto.assoc_loaded?(doc.source), do: doc.source

    collection =
      if source && Ecto.assoc_loaded?(source.collection), do: source.collection

    %{
      "content" => chunk.content,
      "document_title" => if(doc, do: doc.title),
      "source_name" => if(source, do: source.name),
      "collection_name" => if(collection, do: collection.name),
      "relevance_score" => result[:relevance_score]
    }
  end

  defp wrap_result({:ok, data}) do
    {:ok, %{"content" => [%{"type" => "text", "text" => Jason.encode!(data)}]}}
  end

  defp wrap_result({:error, reason}) when is_binary(reason) do
    {:ok, %{"content" => [%{"type" => "text", "text" => Jason.encode!(%{"error" => reason})}]}}
  end
end
