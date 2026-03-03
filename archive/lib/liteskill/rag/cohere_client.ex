defmodule Liteskill.Rag.CohereClient do
  @moduledoc """
  Req-based HTTP client for Cohere rerank on AWS Bedrock.

  Embedding is handled by `ReqLLM.embed/3` via `EmbeddingClient`.
  """

  alias Liteskill.Rag.RequestLogger

  require Logger

  @rerank_model "cohere.rerank-v3-5:0"

  @doc """
  Rerank documents against a query using Cohere rerank-v3.5.

  Optional opts:
    - `top_n` - number of top results (default 5)
    - `max_tokens_per_doc` - max tokens per document (default 4096)
    - `plug` - Req test plug
    - `user_id` - user ID for embedding request tracking
  """
  def rerank(query, documents, opts \\ []) do
    {user_id, opts} = Keyword.pop(opts, :user_id)
    {req_opts, body_opts} = Keyword.split(opts, [:plug])

    body = %{
      "query" => query,
      "documents" => documents,
      "top_n" => Keyword.get(body_opts, :top_n, 5),
      "max_tokens_per_doc" => Keyword.get(body_opts, :max_tokens_per_doc, 4096),
      "api_version" => 2
    }

    start = System.monotonic_time(:millisecond)

    result =
      case Req.post(base_req(), [{:url, invoke_url(@rerank_model)}, {:json, body}] ++ req_opts) do
        {:ok, %{status: 200, body: %{"results" => results}}} ->
          {:ok, results}

        {:ok, %{status: status, body: body}} ->
          {:error, %{status: status, body: body}}

        {:error, reason} ->
          {:error, reason}
      end

    latency = System.monotonic_time(:millisecond) - start

    RequestLogger.log_request(user_id, %{
      request_type: "rerank",
      model_id: @rerank_model,
      input_count: length(documents),
      token_count: RequestLogger.estimate_token_count([query | documents]),
      latency_ms: latency,
      result: result
    })

    result
  end

  defp base_req do
    %{token: token} = resolve_credentials()

    Req.new(
      headers: [
        {"authorization", "Bearer #{token}"},
        {"content-type", "application/json"}
      ],
      retry: false
    )
  end

  defp invoke_url(model_id) do
    %{region: region} = resolve_credentials()
    "https://bedrock-runtime.#{region}.amazonaws.com/model/#{URI.encode(model_id)}/invoke"
  end

  defp resolve_credentials do
    db_creds =
      try do
        Liteskill.LlmProviders.get_bedrock_credentials()
      rescue
        # coveralls-ignore-start
        e in [Postgrex.Error, DBConnection.ConnectionError] ->
          Logger.warning("Failed to resolve DB credentials: #{Exception.message(e)}")
          nil
          # coveralls-ignore-stop
      end

    case db_creds do
      %{api_key: token, region: region} ->
        %{token: token, region: region}

      nil ->
        config = Application.get_env(:liteskill, Liteskill.LLM, [])

        %{
          token: Keyword.get(config, :bedrock_bearer_token),
          region: Keyword.get(config, :bedrock_region, "us-east-1")
        }
    end
  end
end
