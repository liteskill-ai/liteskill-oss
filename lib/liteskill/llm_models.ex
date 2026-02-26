defmodule Liteskill.LlmModels do
  use Boundary,
    top_level?: true,
    deps: [Liteskill.Authorization, Liteskill.LlmProviders, Liteskill.Rbac],
    exports: [LlmModel]

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

  # --- CRUD ---

  def create_model(attrs) do
    with :ok <- validate_provider_ownership(attrs) do
      case %LlmModel{}
           |> LlmModel.changeset(attrs)
           |> Repo.insert() do
        {:ok, model} ->
          {:ok, Repo.preload(model, :provider)}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  def update_model(id, user_id, attrs) do
    case Repo.get(LlmModel, id) do
      nil ->
        {:error, :not_found}

      model ->
        with :ok <- authorize_admin_or_owner(model, user_id) do
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
        with :ok <- authorize_admin_or_owner(model, user_id) do
          Repo.delete(model)
        end
    end
  end

  # --- User-facing queries ---

  def list_models(user_id) do
    accessible_ids = Authorization.usage_accessible_entity_ids("llm_model", user_id)

    LlmModel
    |> where(
      [m],
      m.instance_wide == true or m.user_id == ^user_id or m.id in subquery(accessible_ids)
    )
    |> order_by([m], asc: m.name)
    |> preload(:provider)
    |> Repo.all()
  end

  def list_active_models(user_id, opts \\ []) do
    accessible_ids = Authorization.usage_accessible_entity_ids("llm_model", user_id)

    query =
      LlmModel
      |> join(:inner, [m], p in assoc(m, :provider))
      |> where(
        [m, _p],
        m.instance_wide == true or m.user_id == ^user_id or m.id in subquery(accessible_ids)
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

      %LlmModel{instance_wide: true} = model ->
        {:ok, model}

      %LlmModel{user_id: ^user_id} = model ->
        {:ok, model}

      %LlmModel{} = model ->
        if Authorization.has_usage_access?("llm_model", model.id, user_id) do
          {:ok, model}
        else
          {:error, :not_found}
        end
    end
  end

  @doc "Returns only models owned by the given user, with preloaded provider."
  def list_owned_models(user_id) do
    LlmModel
    |> where([m], m.user_id == ^user_id)
    |> order_by([m], asc: m.name)
    |> preload(:provider)
    |> Repo.all()
  end

  @doc "Returns a model only if the user owns it, with preloaded provider."
  def get_model_for_owner(id, user_id) do
    case Repo.get(LlmModel, id) |> Repo.preload(:provider) do
      nil -> {:error, :not_found}
      %LlmModel{user_id: ^user_id} = model -> {:ok, model}
      %LlmModel{} -> {:error, :forbidden}
    end
  end

  def get_model!(id) do
    Repo.get!(LlmModel, id) |> Repo.preload(:provider)
  end

  @doc """
  Grants usage access (viewer role) on a model to a user.
  Requires the caller to have `llm_models:manage` RBAC permission.
  """
  def grant_usage(model_id, grantee_user_id, admin_user_id) do
    with :ok <- authorize_admin(admin_user_id) do
      Authorization.EntityAcl.changeset(%Authorization.EntityAcl{}, %{
        entity_type: "llm_model",
        entity_id: model_id,
        user_id: grantee_user_id,
        role: "viewer"
      })
      |> Repo.insert()
    end
  end

  @doc """
  Revokes usage access on a model from a user.
  Requires the caller to have `llm_models:manage` RBAC permission.
  """
  def revoke_usage(model_id, target_user_id, admin_user_id) do
    with :ok <- authorize_admin(admin_user_id) do
      case Repo.one(
             from(a in Authorization.EntityAcl,
               where:
                 a.entity_type == "llm_model" and
                   a.entity_id == ^model_id and
                   a.user_id == ^target_user_id
             )
           ) do
        nil -> {:error, :not_found}
        acl -> Repo.delete(acl)
      end
    end
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

    # api_key must be top-level for ReqLLM.Keys.get! (used by streaming path),
    # not nested inside provider_options
    {api_key, provider_opts} = Keyword.pop(provider_opts, :api_key)

    req_opts = [provider_options: provider_opts]
    req_opts = if api_key, do: Keyword.put(req_opts, :api_key, api_key), else: req_opts
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

  # --- Admin helpers ---

  @doc "Returns all models with preloaded provider. No auth filtering — for admin UI only."
  def list_all_models do
    LlmModel
    |> order_by([m], asc: m.name)
    |> preload(:provider)
    |> Repo.all()
  end

  @doc "Returns all active models (optionally filtered by model_type). No auth — for admin UI."
  def list_all_active_models(opts \\ []) do
    query =
      LlmModel
      |> join(:inner, [m], p in assoc(m, :provider))
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

  @doc "Returns a single model with preloaded provider. No auth — for admin edit forms."
  def get_model_for_admin(id) do
    case Repo.get(LlmModel, id) |> Repo.preload(:provider) do
      nil -> {:error, :not_found}
      model -> {:ok, model}
    end
  end

  # --- Private ---

  defp authorize_admin(user_id), do: Liteskill.Rbac.authorize(user_id, "llm_models:manage")

  defp authorize_admin_or_owner(%LlmModel{user_id: uid}, uid), do: :ok

  defp authorize_admin_or_owner(%LlmModel{}, user_id),
    do: authorize_admin(user_id)

  defp validate_provider_ownership(attrs) do
    user_id = attrs[:user_id] || attrs["user_id"]
    provider_id = attrs[:provider_id] || attrs["provider_id"]

    cond do
      is_nil(provider_id) ->
        :ok

      is_nil(user_id) ->
        :ok

      true ->
        case Repo.get(LlmProvider, provider_id) do
          nil ->
            :ok

          %{user_id: ^user_id} ->
            :ok

          %{} ->
            case authorize_admin(user_id) do
              :ok -> :ok
              {:error, :forbidden} -> {:error, :provider_not_owned}
            end
        end
    end
  end
end
