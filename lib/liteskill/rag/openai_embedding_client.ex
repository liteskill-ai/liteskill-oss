defmodule Liteskill.Rag.OpenAIEmbeddingClient do
  @moduledoc """
  Req-based HTTP client for OpenAI-compatible embedding APIs.

  Supports any provider that implements the OpenAI embeddings endpoint format
  (e.g. OpenRouter, OpenAI, Azure OpenAI).
  """

  require Logger

  @doc """
  Embed a list of texts using an OpenAI-compatible API.

  Required opts:
    - `api_key` - API key for authentication
    - `base_url` - base URL of the API (e.g. "https://openrouter.ai/api/v1")
    - `model_id` - model identifier (e.g. "openai/text-embedding-ada-002")

  Optional opts:
    - `dimensions` - output dimension (only sent for text-embedding-3-* models)
    - `plug` - Req test plug
    - `user_id` - user ID for embedding request tracking
  """
  def embed(texts, opts \\ []) do
    api_key = Keyword.fetch!(opts, :api_key)
    base_url = Keyword.fetch!(opts, :base_url)
    model_id = Keyword.fetch!(opts, :model_id)
    dimensions = Keyword.get(opts, :dimensions)
    plug_opt = Keyword.get(opts, :plug)

    body =
      %{"model" => model_id, "input" => texts}
      |> maybe_add_dimensions(model_id, dimensions)

    req =
      Req.new(
        url: "#{String.trim_trailing(base_url, "/")}/embeddings",
        headers: [
          {"authorization", "Bearer #{api_key}"},
          {"content-type", "application/json"}
        ],
        retry: false
      )

    req_opts = [json: body]
    req_opts = if plug_opt, do: [{:plug, plug_opt} | req_opts], else: req_opts

    case Req.post(req, req_opts) do
      {:ok, %{status: 200, body: %{"data" => data}}} ->
        embeddings =
          data
          |> Enum.sort_by(fn %{"index" => idx} -> idx end)
          |> Enum.map(fn %{"embedding" => emb} -> emb end)

        {:ok, embeddings}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      # coveralls-ignore-next-line
      {:error, reason} ->
        {:error, reason}
    end
  end

  # Only text-embedding-3-* models support the dimensions parameter.
  # ada-002 and other older models don't accept it.
  defp maybe_add_dimensions(body, model_id, dimensions) when is_integer(dimensions) do
    if String.contains?(model_id, "text-embedding-3") do
      Map.put(body, "dimensions", dimensions)
    else
      body
    end
  end

  defp maybe_add_dimensions(body, _model_id, _dimensions), do: body
end
