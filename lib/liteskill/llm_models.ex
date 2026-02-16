defmodule Liteskill.LlmModels do
  @moduledoc """
  Context for managing LLM model configurations.

  Each model references an LLM provider for endpoint credentials.
  Admin-only CRUD; user access via instance_wide flag or entity ACLs.
  """

  alias Liteskill.Authorization
  alias Liteskill.LlmModels.LlmModel
  alias Liteskill.LlmProviders.LlmProvider
  alias Liteskill.Repo

  import Ecto.Query

  require Logger

  # --- Admin CRUD ---

  def create_model(attrs) do
    Repo.transaction(fn ->
      case %LlmModel{}
           |> LlmModel.changeset(attrs)
           |> Repo.insert() do
        {:ok, model} ->
          {:ok, _} = Authorization.create_owner_acl("llm_model", model.id, model.user_id)
          Repo.preload(model, :provider)

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  def update_model(id, user_id, attrs) do
    case Repo.get(LlmModel, id) do
      nil ->
        {:error, :not_found}

      model ->
        with {:ok, model} <- authorize_owner(model, user_id) do
          model
          |> LlmModel.changeset(attrs)
          |> Repo.update()
          |> case do
            {:ok, updated} -> {:ok, Repo.preload(updated, :provider)}
            error -> error
          end
        end
    end
  end

  def delete_model(id, user_id) do
    case Repo.get(LlmModel, id) do
      nil ->
        {:error, :not_found}

      model ->
        with {:ok, model} <- authorize_owner(model, user_id) do
          Repo.delete(model)
        end
    end
  end

  # --- User-facing queries ---

  def list_models(user_id) do
    accessible_ids = Authorization.accessible_entity_ids("llm_model", user_id)

    LlmModel
    |> where(
      [m],
      m.user_id == ^user_id or m.instance_wide == true or m.id in subquery(accessible_ids)
    )
    |> order_by([m], asc: m.name)
    |> preload(:provider)
    |> Repo.all()
  end

  def list_active_models(user_id, opts \\ []) do
    accessible_ids = Authorization.accessible_entity_ids("llm_model", user_id)

    query =
      LlmModel
      |> join(:inner, [m], p in assoc(m, :provider))
      |> where(
        [m, _p],
        m.user_id == ^user_id or m.instance_wide == true or m.id in subquery(accessible_ids)
      )
      |> where([m, _p], m.status == "active")
      |> where([_m, p], p.status == "active")

    query =
      case Keyword.get(opts, :model_type) do
        nil -> query
        model_type -> where(query, [m], m.model_type == ^model_type)
      end

    query
    |> order_by([m], asc: m.name)
    |> preload(:provider)
    |> Repo.all()
  end

  def get_model(id, user_id) do
    case Repo.get(LlmModel, id) |> Repo.preload(:provider) do
      nil ->
        {:error, :not_found}

      %LlmModel{user_id: ^user_id} = model ->
        {:ok, model}

      %LlmModel{instance_wide: true} = model ->
        {:ok, model}

      %LlmModel{} = model ->
        if Authorization.has_access?("llm_model", model.id, user_id) do
          {:ok, model}
        else
          {:error, :not_found}
        end
    end
  end

  def get_model!(id) do
    Repo.get!(LlmModel, id) |> Repo.preload(:provider)
  end

  # --- Provider options builder ---

  @doc """
  Builds ReqLLM-compatible provider options from a model + its preloaded provider.

  Returns `{model_spec, req_opts}` where:
  - `model_spec` is `%{id: model_id, provider: provider_atom}`
  - `req_opts` is a keyword list including `provider_options`

  ## Options

  - `:enable_caching` — when `true`, enables Anthropic prompt caching for
    Bedrock Anthropic models. Switches to native API (`use_converse: false`)
    for full message caching support with tools.
  """
  def build_provider_options(model, opts \\ [])

  def build_provider_options(%LlmModel{provider: %LlmProvider{} = provider} = m, opts) do
    provider_atom = String.to_existing_atom(provider.provider_type)
    model_spec = %{id: m.model_id, provider: provider_atom}

    base_opts = if provider.api_key, do: [api_key: provider.api_key], else: []
    config = provider.provider_config || %{}

    # base_url is a top-level ReqLLM option, not inside provider_options
    {base_url, config} = Map.pop(config, "base_url")

    provider_opts =
      case provider_atom do
        :amazon_bedrock ->
          region = Map.get(config, "region", "us-east-1")
          [{:region, region}, {:use_converse, true} | base_opts]

        :azure ->
          azure_opts =
            [
              {:resource_name, config["resource_name"]},
              {:deployment_id, config["deployment_id"]},
              {:api_version, config["api_version"]}
            ]
            |> Enum.reject(fn {_, v} -> is_nil(v) end)

          azure_opts ++ base_opts

        _other ->
          atomize_config(config) ++ base_opts
      end

    provider_opts = maybe_enable_caching(provider_opts, m, opts)

    req_opts = [provider_options: provider_opts]
    req_opts = if base_url, do: Keyword.put(req_opts, :base_url, base_url), else: req_opts

    {model_spec, req_opts}
  end

  defp maybe_enable_caching(provider_opts, model, opts) do
    if Keyword.get(opts, :enable_caching, false) && anthropic_bedrock?(model) do
      # Switch to native Anthropic API (not Converse) for caching support.
      # anthropic_prompt_cache is set separately by LlmGenerate based on
      # tool count, because ReqLLM adds cache_control to EVERY tool and
      # Bedrock limits total cache_control blocks to 4.
      Keyword.put(provider_opts, :use_converse, false)
    else
      provider_opts
    end
  end

  defp anthropic_bedrock?(%LlmModel{
         model_id: model_id,
         provider: %LlmProvider{provider_type: "amazon_bedrock"}
       })
       when is_binary(model_id) do
    String.contains?(model_id, "anthropic")
  end

  defp anthropic_bedrock?(_), do: false

  defp atomize_config(config) do
    Enum.reduce(config, [], fn {k, v}, acc ->
      try do
        [{String.to_existing_atom(k), v} | acc]
      rescue
        _e in [ArgumentError] ->
          Logger.warning("LlmModels: dropping unknown provider config key #{inspect(k)}")
          acc
      end
    end)
  end

  # --- Private ---

  defp authorize_owner(entity, user_id), do: Authorization.authorize_owner(entity, user_id)
end
