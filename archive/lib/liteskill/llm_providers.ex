defmodule Liteskill.LlmProviders do
  @moduledoc """
  Context for managing LLM provider configurations.

  Each provider represents a connection endpoint with credentials.
  Admin-only CRUD; access via instance_wide flag or entity ACLs.
  """

  use Boundary,
    top_level?: true,
    deps: [Liteskill.Accounts, Liteskill.Authorization, Liteskill.Rbac],
    exports: [LlmProvider]

  import Ecto.Query

  alias Liteskill.Authorization
  alias Liteskill.LlmProviders.LlmProvider
  alias Liteskill.Repo

  # --- CRUD ---

  def create_provider(attrs) do
    case %LlmProvider{}
         |> LlmProvider.changeset(attrs)
         |> Repo.insert() do
      {:ok, provider} ->
        {:ok, provider}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def update_provider(id, user_id, attrs) do
    case Repo.get(LlmProvider, id) do
      nil ->
        {:error, :not_found}

      provider ->
        with :ok <- authorize_admin_or_owner(provider, user_id) do
          provider
          |> LlmProvider.changeset(attrs)
          |> Repo.update()
        end
    end
  end

  def delete_provider(id, user_id) do
    case Repo.get(LlmProvider, id) do
      nil ->
        {:error, :not_found}

      provider ->
        with :ok <- authorize_admin_or_owner(provider, user_id) do
          Repo.delete(provider)
        end
    end
  end

  # --- User-facing queries ---

  def list_providers(user_id) do
    accessible_ids = Authorization.usage_accessible_entity_ids("llm_provider", user_id)

    LlmProvider
    |> where(
      [p],
      p.instance_wide == true or p.user_id == ^user_id or p.id in subquery(accessible_ids)
    )
    |> order_by([p], asc: p.name)
    |> Repo.all()
  end

  def get_provider(id, user_id) do
    case Repo.get(LlmProvider, id) do
      nil ->
        {:error, :not_found}

      %LlmProvider{instance_wide: true} = provider ->
        {:ok, provider}

      %LlmProvider{user_id: ^user_id} = provider ->
        {:ok, provider}

      %LlmProvider{} = provider ->
        if Authorization.has_usage_access?("llm_provider", provider.id, user_id) do
          {:ok, provider}
        else
          {:error, :not_found}
        end
    end
  end

  @doc "Returns only providers owned by the given user."
  def list_owned_providers(user_id) do
    LlmProvider
    |> where([p], p.user_id == ^user_id)
    |> order_by([p], asc: p.name)
    |> Repo.all()
  end

  @doc "Returns a provider only if the user owns it."
  def get_provider_for_owner(id, user_id) do
    case Repo.get(LlmProvider, id) do
      nil -> {:error, :not_found}
      %LlmProvider{user_id: ^user_id} = provider -> {:ok, provider}
      %LlmProvider{} -> {:error, :forbidden}
    end
  end

  def get_provider!(id) do
    Repo.get!(LlmProvider, id)
  end

  @doc """
  Grants usage access (viewer role) on a provider to a user.
  Requires the caller to have `llm_providers:manage` RBAC permission.
  """
  def grant_usage(provider_id, grantee_user_id, admin_user_id) do
    with :ok <- authorize_admin(admin_user_id) do
      %Authorization.EntityAcl{}
      |> Authorization.EntityAcl.changeset(%{
        entity_type: "llm_provider",
        entity_id: provider_id,
        user_id: grantee_user_id,
        role: "viewer"
      })
      |> Repo.insert()
    end
  end

  @doc """
  Revokes usage access on a provider from a user.
  Requires the caller to have `llm_providers:manage` RBAC permission.
  """
  def revoke_usage(provider_id, target_user_id, admin_user_id) do
    with :ok <- authorize_admin(admin_user_id) do
      case Repo.one(
             from(a in Authorization.EntityAcl,
               where:
                 a.entity_type == "llm_provider" and
                   a.entity_id == ^provider_id and
                   a.user_id == ^target_user_id
             )
           ) do
        nil -> {:error, :not_found}
        acl -> Repo.delete(acl)
      end
    end
  end

  # --- Environment bootstrap ---

  @env_provider_name "Bedrock (environment)"

  @doc """
  Creates or updates an instance-wide Bedrock provider from env var config.

  Called on application boot (non-test). If `bedrock_bearer_token` is set in
  app config, finds-or-creates a provider named "Bedrock (environment)" owned
  by the admin user. Idempotent — safe to call on every boot.
  """
  def ensure_env_providers do
    config = Application.get_env(:liteskill, Liteskill.LLM, [])
    token = Keyword.get(config, :bedrock_bearer_token)

    if token do
      region = Keyword.get(config, :bedrock_region, "us-east-1")
      admin = Liteskill.Accounts.get_user_by_email(Liteskill.Accounts.User.admin_email())

      if admin do
        upsert_env_provider(admin.id, token, region)
      end
    end

    :ok
  end

  defp upsert_env_provider(admin_id, token, region) do
    case Repo.get_by(LlmProvider, name: @env_provider_name, user_id: admin_id) do
      nil ->
        create_provider(%{
          name: @env_provider_name,
          provider_type: "amazon_bedrock",
          api_key: token,
          provider_config: %{"region" => region},
          instance_wide: true,
          user_id: admin_id
        })

      provider ->
        provider
        |> LlmProvider.changeset(%{
          api_key: token,
          provider_config: %{"region" => region},
          status: "active"
        })
        |> Repo.update()
    end
  end

  @doc """
  Returns Bedrock credentials from the first active instance-wide Bedrock provider.

  Returns `%{api_key: token, region: region}` or `nil` if none found.
  """
  def get_bedrock_credentials do
    query =
      from p in LlmProvider,
        where:
          p.provider_type == "amazon_bedrock" and
            p.instance_wide == true and
            p.status == "active",
        limit: 1

    case Repo.one(query) do
      nil ->
        nil

      provider ->
        %{
          api_key: provider.api_key,
          region: get_in(provider.provider_config, ["region"]) || "us-east-1"
        }
    end
  end

  # --- Admin helpers ---

  @doc "Returns all providers. No auth filtering — for admin UI only."
  def list_all_providers do
    LlmProvider
    |> order_by([p], asc: p.name)
    |> Repo.all()
  end

  @doc "Returns a single provider. No auth — for admin edit forms."
  def get_provider_for_admin(id) do
    case Repo.get(LlmProvider, id) do
      nil -> {:error, :not_found}
      provider -> {:ok, provider}
    end
  end

  @doc "Finds a provider by name and owner user_id."
  def get_provider_by_name(name, user_id) do
    Repo.get_by(LlmProvider, name: name, user_id: user_id)
  end

  @doc "Updates a provider record directly (no auth check — caller must authorize)."
  def update_provider_record(%LlmProvider{} = provider, attrs) do
    provider
    |> LlmProvider.changeset(attrs)
    |> Repo.update()
  end

  # --- Private ---

  defp authorize_admin(user_id), do: Liteskill.Rbac.authorize(user_id, "llm_providers:manage")

  defp authorize_admin_or_owner(%LlmProvider{user_id: uid}, uid), do: :ok

  defp authorize_admin_or_owner(%LlmProvider{}, user_id), do: authorize_admin(user_id)
end
