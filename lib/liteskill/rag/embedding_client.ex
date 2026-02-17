defmodule Liteskill.Rag.EmbeddingClient do
  @moduledoc """
  Facade for embedding API calls. Dispatches to the appropriate backend
  based on the configured embedding model's provider type.

  - `amazon_bedrock` → `CohereClient` (Cohere on Bedrock)
  - Everything else → `OpenAIEmbeddingClient` (OpenAI-compatible API)
  - No model configured → falls back to `CohereClient` (backward compat)
  """

  alias Liteskill.Rag.{CohereClient, EmbeddingRequest, OpenAIEmbeddingClient}
  alias Liteskill.{LlmProviders, Repo, Settings}

  require Logger

  @default_base_urls %{
    "openrouter" => "https://openrouter.ai/api/v1",
    "openai" => "https://api.openai.com/v1"
  }

  @doc """
  Embed a list of texts using the currently configured embedding provider.

  Accepts the same opts as `CohereClient.embed/2`.
  """
  def embed(texts, opts \\ []) do
    case resolve_provider() do
      {:bedrock, _model} ->
        CohereClient.embed(texts, remap_plug(opts, CohereClient))

      {:openai_compat, model, provider} ->
        {user_id, opts} = Keyword.pop(opts, :user_id)
        plug_opt = remap_plug_opt(opts)

        openai_opts =
          [
            api_key: provider.api_key,
            base_url: resolve_base_url(provider),
            model_id: model.model_id
          ] ++ plug_opt

        start = System.monotonic_time(:millisecond)
        result = OpenAIEmbeddingClient.embed(texts, openai_opts)
        latency = System.monotonic_time(:millisecond) - start

        log_request(user_id, %{
          request_type: "embed",
          model_id: model.model_id,
          input_count: length(texts),
          token_count: estimate_token_count(texts),
          latency_ms: latency,
          result: result
        })

        result

      :no_model ->
        CohereClient.embed(texts, remap_plug(opts, CohereClient))
    end
  end

  # Remap plug: {Req.Test, EmbeddingClient} → {Req.Test, target_module}
  defp remap_plug(opts, target) do
    case Keyword.get(opts, :plug) do
      {Req.Test, __MODULE__} -> Keyword.put(opts, :plug, {Req.Test, target})
      _ -> opts
    end
  end

  defp remap_plug_opt(opts) do
    case Keyword.get(opts, :plug) do
      {Req.Test, __MODULE__} -> [plug: {Req.Test, OpenAIEmbeddingClient}]
      # coveralls-ignore-next-line
      nil -> []
      plug -> [plug: plug]
    end
  end

  defp resolve_provider do
    settings = Settings.get()

    # Check embedding_model_id (not embedding_model) to avoid
    # Ecto.Association.NotLoaded when no settings record exists
    if is_nil(settings.embedding_model_id) do
      :no_model
    else
      model = settings.embedding_model
      provider = LlmProviders.get_provider!(model.provider_id)

      if provider.provider_type == "amazon_bedrock" do
        {:bedrock, model}
      else
        {:openai_compat, model, provider}
      end
    end
  end

  defp resolve_base_url(provider) do
    config_url = get_in(provider.provider_config || %{}, ["base_url"])
    config_url || Map.get(@default_base_urls, provider.provider_type, "https://api.openai.com/v1")
  end

  # coveralls-ignore-next-line
  defp log_request(nil, _attrs), do: :ok

  defp log_request(user_id, attrs) do
    {status, error_message} =
      case attrs.result do
        {:ok, _} -> {"success", nil}
        {:error, %{status: s}} -> {"error", "HTTP #{s}"}
        # coveralls-ignore-next-line
        {:error, _} -> {"error", "request_failed"}
      end

    try do
      %EmbeddingRequest{}
      |> EmbeddingRequest.changeset(%{
        request_type: attrs.request_type,
        status: status,
        latency_ms: attrs.latency_ms,
        input_count: attrs.input_count,
        token_count: attrs.token_count,
        model_id: attrs.model_id,
        error_message: error_message,
        user_id: user_id
      })
      |> Repo.insert()
    rescue
      # coveralls-ignore-start
      _ ->
        :ok
        # coveralls-ignore-stop
    end
  end

  defp estimate_token_count(texts) do
    texts
    |> Enum.map(fn text ->
      text |> String.split(~r/\s+/) |> length() |> Kernel.*(4) |> div(3)
    end)
    |> Enum.sum()
  end
end
