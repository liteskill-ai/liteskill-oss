defmodule Liteskill.EmbeddingCatalog do
  @moduledoc """
  Embedding model catalog with dynamic fetching from OpenRouter's
  `/api/v1/embeddings/models` endpoint, falling back to a curated static catalog.

  The static catalog enriches dynamic models with extra metadata like
  `dimensions` and multi-provider compatibility.
  """

  @catalog [
    %{
      id: "openai/text-embedding-3-small",
      name: "OpenAI Text Embedding 3 Small",
      model_type: "embedding",
      dimensions: 1536,
      max_tokens: 8191,
      compatible_providers: ["openrouter", "openai"],
      input_cost_per_million: Decimal.new("0.02"),
      output_cost_per_million: nil
    },
    %{
      id: "openai/text-embedding-3-large",
      name: "OpenAI Text Embedding 3 Large",
      model_type: "embedding",
      dimensions: 3072,
      max_tokens: 8191,
      compatible_providers: ["openrouter", "openai"],
      input_cost_per_million: Decimal.new("0.13"),
      output_cost_per_million: nil
    },
    %{
      id: "openai/text-embedding-ada-002",
      name: "OpenAI Ada 002",
      model_type: "embedding",
      dimensions: 1536,
      max_tokens: 8191,
      compatible_providers: ["openrouter", "openai"],
      input_cost_per_million: Decimal.new("0.10"),
      output_cost_per_million: nil
    },
    %{
      id: "cohere/embed-english-v3.0",
      name: "Cohere Embed English v3",
      model_type: "embedding",
      dimensions: 1024,
      max_tokens: 512,
      compatible_providers: ["openrouter"],
      input_cost_per_million: Decimal.new("0.10"),
      output_cost_per_million: nil
    },
    %{
      id: "cohere/embed-multilingual-v3.0",
      name: "Cohere Embed Multilingual v3",
      model_type: "embedding",
      dimensions: 1024,
      max_tokens: 512,
      compatible_providers: ["openrouter"],
      input_cost_per_million: Decimal.new("0.10"),
      output_cost_per_million: nil
    },
    %{
      id: "google/text-embedding-004",
      name: "Google Text Embedding 004",
      model_type: "embedding",
      dimensions: 768,
      max_tokens: 2048,
      compatible_providers: ["openrouter", "google"],
      input_cost_per_million: Decimal.new("0.006"),
      output_cost_per_million: nil
    },
    %{
      id: "mistralai/mistral-embed",
      name: "Mistral Embed",
      model_type: "embedding",
      dimensions: 1024,
      max_tokens: 8192,
      compatible_providers: ["openrouter", "mistral"],
      input_cost_per_million: Decimal.new("0.10"),
      output_cost_per_million: nil
    }
  ]

  @doc """
  Fetches embedding models from OpenRouter, enriched with static catalog metadata.
  Falls back to the static catalog on API failure.

  Dynamic models are enriched with `dimensions` and `compatible_providers` from
  matching static entries. Models not in the static catalog get
  `compatible_providers: ["openrouter"]` and `dimensions: nil`.
  """
  def fetch_models do
    case Liteskill.OpenRouter.Models.list_embedding_models() do
      {:ok, models} -> enrich_models(models)
      {:error, _} -> @catalog
    end
  end

  @doc """
  Returns the full static catalog of curated embedding models.
  """
  def list_models, do: @catalog

  @doc """
  Filters models by compatibility with at least one of the given provider types.
  Works with both static catalog entries and dynamically-fetched models.
  """
  def filter_for_providers(models, provider_types) when is_list(provider_types) do
    type_set = MapSet.new(provider_types)

    Enum.filter(models, fn model ->
      providers = Map.get(model, :compatible_providers, ["openrouter"])

      Enum.any?(providers, &MapSet.member?(type_set, &1))
    end)
  end

  @doc """
  Returns static catalog entries compatible with at least one of the given provider types.
  """
  def list_for_providers(provider_types) when is_list(provider_types) do
    filter_for_providers(@catalog, provider_types)
  end

  @doc """
  Searches models by substring match on id or name (case-insensitive).
  Optionally filtered by provider types.
  """
  def search(query, provider_types \\ nil) do
    base = if provider_types, do: list_for_providers(provider_types), else: @catalog
    filter_by_query(base, query)
  end

  @doc """
  Searches a given list of models by substring match on id or name (case-insensitive).
  """
  def search_models(models, query) do
    filter_by_query(models, query)
  end

  @doc """
  Finds a single catalog entry by its model ID. Returns nil if not found.
  """
  def get_model(model_id) do
    Enum.find(@catalog, &(&1.id == model_id))
  end

  @doc """
  Picks the best matching provider from the user's configured providers
  for a model. Returns `{:ok, provider_id}` or `:error`.

  Preference follows the order in the model's `compatible_providers` list.
  """
  def resolve_provider(model, user_providers) do
    providers = Map.get(model, :compatible_providers, ["openrouter"])

    result =
      Enum.find_value(providers, fn compat_type ->
        case Enum.find(user_providers, &(&1.provider_type == compat_type)) do
          nil -> nil
          provider -> provider.id
        end
      end)

    case result do
      nil -> :error
      provider_id -> {:ok, provider_id}
    end
  end

  defp enrich_models(dynamic_models) do
    static_by_id = Map.new(@catalog, &{&1.id, &1})

    Enum.map(dynamic_models, fn model ->
      case Map.get(static_by_id, model.id) do
        nil ->
          Map.merge(model, %{
            compatible_providers: ["openrouter"],
            dimensions: nil
          })

        static ->
          Map.merge(model, %{
            compatible_providers: static.compatible_providers,
            dimensions: static.dimensions
          })
      end
    end)
  end

  defp filter_by_query(models, query) do
    q = String.downcase(query)

    Enum.filter(models, fn m ->
      String.contains?(String.downcase(m.id), q) ||
        String.contains?(String.downcase(m.name), q)
    end)
  end
end
