defmodule Liteskill.Rag.IngestWorker do
  @moduledoc """
  Oban worker that ingests a URL into the RAG store.

  Pipeline: fetch URL → validate text content → find/create source →
  create document → chunk text → embed chunks.
  """

  use Oban.Worker, queue: :rag_ingest, max_attempts: 3

  alias Liteskill.Rag
  alias Liteskill.Rag.{Chunker, Source}
  alias Liteskill.Repo

  import Ecto.Query

  @text_content_types [
    "text/",
    "application/json",
    "application/xml",
    "application/yaml",
    "application/javascript",
    "application/xhtml+xml",
    "application/rss+xml",
    "application/atom+xml"
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    url = Map.fetch!(args, "url")
    collection_id = Map.fetch!(args, "collection_id")
    user_id = Map.fetch!(args, "user_id")
    method = Map.get(args, "method", "GET")
    headers = Map.get(args, "headers", %{})
    chunk_opts = Map.get(args, "chunk_opts", %{})
    plug = Map.get(args, "plug", false)

    with {:ok, response} <- fetch_url(url, method, headers, plug),
         {:ok, _status} <- check_status(response),
         {:ok, content_type} <- extract_content_type(response),
         :ok <- validate_text_content(content_type),
         body = normalize_body(response.body),
         {:ok, source} <- find_or_create_source(url, collection_id, user_id),
         {:ok, document} <- create_document(url, body, content_type, source, user_id),
         chunks <- chunk_text(body, chunk_opts),
         {:ok, _} <- embed_chunks(document, chunks, user_id, plug) do
      :ok
    end
  end

  @allowed_methods %{
    "get" => :get,
    "post" => :post,
    "put" => :put,
    "patch" => :patch,
    "delete" => :delete,
    "head" => :head,
    "options" => :options
  }

  defp fetch_url(url, method, headers, plug) do
    # coveralls-ignore-start
    method_atom =
      Map.get(@allowed_methods, String.downcase(method)) ||
        raise ArgumentError, "unsupported HTTP method: #{method}"

    # coveralls-ignore-stop

    header_list =
      Enum.map(headers, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)

    req_opts = [url: url, method: method_atom, headers: header_list]

    req_opts =
      if plug do
        [{:plug, {Req.Test, __MODULE__}} | req_opts]
      else
        # coveralls-ignore-next-line
        req_opts
      end

    case Req.request(Req.new(retry: false), req_opts) do
      {:ok, response} ->
        {:ok, response}

      # coveralls-ignore-start
      {:error, reason} ->
        {:error, reason}
        # coveralls-ignore-stop
    end
  end

  defp check_status(%{status: status}) when status >= 200 and status < 300 do
    {:ok, status}
  end

  defp check_status(%{status: status}) do
    {:error, {:http_status, status}}
  end

  defp extract_content_type(%{headers: headers}) do
    raw =
      case headers do
        %{} ->
          Map.get(headers, "content-type", []) |> List.first()

        # coveralls-ignore-start
        list when is_list(list) ->
          Enum.find_value(list, fn
            {"content-type", value} -> value
            _ -> nil
          end)

          # coveralls-ignore-stop
      end

    case raw do
      nil -> {:ok, "text/plain"}
      value -> {:ok, value |> String.split(";") |> List.first() |> String.trim()}
    end
  end

  defp validate_text_content(content_type) do
    if text_content?(content_type) do
      :ok
    else
      {:cancel, :binary_content}
    end
  end

  defp text_content?(content_type) do
    Enum.any?(@text_content_types, fn allowed ->
      String.starts_with?(content_type, allowed)
    end)
  end

  defp find_or_create_source(url, collection_id, user_id) do
    %URI{host: host} = URI.parse(url)
    domain = host || "unknown"

    case Repo.one(
           from(s in Source,
             where:
               s.collection_id == ^collection_id and
                 s.name == ^domain and
                 s.user_id == ^user_id
           )
         ) do
      nil ->
        Rag.create_source(collection_id, %{name: domain, source_type: "web"}, user_id)

      %Source{} = source ->
        {:ok, source}
    end
  end

  defp create_document(url, body, content_type, source, user_id) do
    path = URI.parse(url).path || "/"

    Rag.create_document(
      source.id,
      %{
        title: path,
        content: body,
        metadata: %{"url" => url, "content_type" => content_type}
      },
      user_id
    )
  end

  defp chunk_text(body, chunk_opts) do
    opts =
      []
      |> maybe_put(:chunk_size, Map.get(chunk_opts, "chunk_size"))
      |> maybe_put(:overlap, Map.get(chunk_opts, "overlap"))

    Chunker.split(body, opts)
  end

  defp normalize_body(body) when is_binary(body), do: body
  defp normalize_body(body), do: Jason.encode!(body)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp embed_chunks(document, chunks, user_id, plug) do
    embed_opts =
      if plug do
        [plug: {Req.Test, Liteskill.Rag.EmbeddingClient}]
      else
        []
      end

    Rag.embed_chunks(document.id, chunks, user_id, embed_opts)
  end
end
