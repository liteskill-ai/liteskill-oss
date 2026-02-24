defmodule Liteskill.Rag.EmbeddingClient do
  @moduledoc """
  Facade for embedding API calls. Delegates to `ReqLLM.embed/3` for Bedrock
  providers and uses direct Req HTTP for OpenAI-compatible providers.

  Falls back to Bedrock Cohere embed-v4 when no model is configured.
  """

  alias Liteskill.Rag.RequestLogger
  alias Liteskill.{LlmModels, LlmProviders, Settings}

  require Logger

  @default_embed_model "us.cohere.embed-v4:0"

  @default_base_urls %{
    "openrouter" => "https://openrouter.ai/api/v1",
    "openai" => "https://api.openai.com/v1"
  }

  @doc """
  Embed a list of texts using the currently configured embedding provider.

  ## Options

    * `:input_type` - "search_document" or "search_query" (default "search_document")
    * `:dimensions` - output dimension (default 1024)
    * `:truncate` - truncation strategy (default "RIGHT")
    * `:plug` - Req test plug (passed through as `req_http_options: [plug: ...]`)
    * `:user_id` - user ID for embedding request tracking
  """
  def embed(texts, opts) do
    {user_id, opts} = Keyword.pop(opts, :user_id)
    {plug_opt, embed_opts} = Keyword.pop(opts, :plug)

    start = System.monotonic_time(:millisecond)

    {result, log_model_id} =
      case resolve_provider() do
        {:openai_compat, model, provider} ->
          {embed_openai_compat(texts, model, provider, embed_opts, plug_opt), model.model_id}

        provider_info ->
          {model_spec, req_opts, model_id} = build_bedrock_options(provider_info, embed_opts)

          req_opts =
            if plug_opt,
              do: Keyword.put(req_opts, :req_http_options, plug: plug_opt),
              else: req_opts

          {ReqLLM.embed(model_spec, texts, req_opts), model_id}
      end

    latency = System.monotonic_time(:millisecond) - start

    RequestLogger.log_request(user_id, %{
      request_type: "embed",
      model_id: log_model_id,
      input_count: length(texts),
      token_count: RequestLogger.estimate_token_count(texts),
      latency_ms: latency,
      result: result
    })

    result
  end

  # Direct Req HTTP for OpenAI-compatible providers (OpenRouter, OpenAI, etc.).
  # ReqLLM.embed/3 strips provider prefixes from model IDs via LLMDB resolution,
  # which breaks providers like OpenRouter that require the full model ID
  # (e.g. "openai/text-embedding-ada-002" not "text-embedding-ada-002").
  defp embed_openai_compat(texts, model, provider, opts, plug_opt) do
    {dimensions, _opts} = Keyword.pop(opts, :dimensions, 1024)
    base_url = resolve_base_url(provider)

    body = %{model: model.model_id, input: texts}
    # Only include dimensions for models that support it (e.g. text-embedding-3-*).
    # Older models like text-embedding-ada-002 have fixed output dimensions and
    # reject the parameter.
    body =
      if supports_dimensions?(model.model_id),
        do: Map.put(body, :dimensions, dimensions),
        else: body

    req_opts = [
      url: "#{base_url}/embeddings",
      json: body,
      headers: [{"authorization", "Bearer #{provider.api_key}"}]
    ]

    req_opts = if plug_opt, do: Keyword.put(req_opts, :plug, plug_opt), else: req_opts

    case Req.post(req_opts) do
      {:ok, %{status: status, body: %{"data" => data}}} when status in 200..299 ->
        embeddings = data |> Enum.sort_by(& &1["index"]) |> Enum.map(& &1["embedding"])
        {:ok, embeddings}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      # coveralls-ignore-start — Req.Test always returns {:ok, _}
      {:error, reason} ->
        {:error, reason}
        # coveralls-ignore-stop
    end
  end

  defp build_bedrock_options(provider_info, opts) do
    {input_type, opts} = Keyword.pop(opts, :input_type, "search_document")
    {_dimensions, opts} = Keyword.pop(opts, :dimensions, 1024)
    {truncate, _opts} = Keyword.pop(opts, :truncate, "RIGHT")

    case provider_info do
      {:bedrock, model, provider} ->
        region = get_in(provider.provider_config || %{}, ["region"]) || "us-east-1"

        # Note: :dimensions is intentionally omitted from Bedrock provider_options.
        # ReqLLM's Bedrock provider schema does not declare it (upstream gap);
        # Cohere embed-v4 defaults to 1024 dimensions which matches our default.
        req_opts = [
          provider_options: [
            region: region,
            input_type: input_type,
            truncate: truncate
          ]
        ]

        req_opts =
          if provider.api_key,
            do: Keyword.put(req_opts, :api_key, provider.api_key),
            # coveralls-ignore-next-line
            else: req_opts

        {"amazon_bedrock:#{model.model_id}", req_opts, model.model_id}

      :no_model ->
        creds = resolve_bedrock_credentials()

        # Note: :dimensions omitted — same upstream gap as {:bedrock, ...} above.
        req_opts = [
          provider_options: [
            region: creds.region,
            input_type: input_type,
            truncate: truncate
          ]
        ]

        req_opts =
          if creds.token, do: Keyword.put(req_opts, :api_key, creds.token), else: req_opts

        {"amazon_bedrock:#{@default_embed_model}", req_opts, @default_embed_model}
    end
  end

  # Models with variable output dimensions (text-embedding-3-* family).
  # Older models (ada-002, etc.) have fixed dimensions and reject the parameter.
  defp supports_dimensions?(model_id) do
    canonical = model_id |> String.split("/") |> List.last()
    String.starts_with?(canonical, "text-embedding-3")
  end

  defp resolve_provider do
    settings = Settings.get()

    if is_nil(settings.embedding_model_id) do
      :no_model
    else
      model = LlmModels.get_model!(settings.embedding_model_id)
      provider = model.provider

      if provider.provider_type == "amazon_bedrock" do
        {:bedrock, model, provider}
      else
        {:openai_compat, model, provider}
      end
    end
  end

  defp resolve_base_url(provider) do
    config_url = get_in(provider.provider_config || %{}, ["base_url"])
    config_url || Map.get(@default_base_urls, provider.provider_type, "https://api.openai.com/v1")
  end

  defp resolve_bedrock_credentials do
    db_creds =
      try do
        LlmProviders.get_bedrock_credentials()
      rescue
        # coveralls-ignore-start
        e ->
          Logger.warning("Failed to resolve DB credentials: #{Exception.message(e)}")
          nil
          # coveralls-ignore-stop
      end

    case db_creds do
      # coveralls-ignore-start — tested via CohereClient.rerank DB credentials test
      %{api_key: token, region: region} ->
        %{token: token, region: region}

      # coveralls-ignore-stop
      nil ->
        config = Application.get_env(:liteskill, Liteskill.LLM, [])

        %{
          token: Keyword.get(config, :bedrock_bearer_token),
          region: Keyword.get(config, :bedrock_region, "us-east-1")
        }
    end
  end
end
