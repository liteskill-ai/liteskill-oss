defmodule Liteskill.LlmProviders do
  use Boundary,
    top_level?: true,
    deps: [Liteskill.Accounts, Liteskill.Authorization],
    exports: [LlmProvider]

  @moduledoc """
  Context for managing LLM provider configurations.

  Each provider represents a connection endpoint with credentials.
  Admin-only CRUD; access via instance_wide flag or entity ACLs.
  """

  alias Liteskill.Authorization
  alias Liteskill.LlmProviders.LlmProvider
  alias Liteskill.Repo

  import Ecto.Query

  # --- Admin CRUD ---

  def create_provider(attrs) do
    Repo.transaction(fn ->
      case %LlmProvider{}
           |> LlmProvider.changeset(attrs)
           |> Repo.insert() do
        {:ok, provider} ->
          {:ok, _} = Authorization.create_owner_acl("llm_provider", provider.id, provider.user_id)
          provider

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  def update_provider(id, user_id, attrs) do
    case Repo.get(LlmProvider, id) do
      nil ->
        {:error, :not_found}

      provider ->
        with {:ok, provider} <- authorize_owner(provider, user_id) do
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
        with {:ok, provider} <- authorize_owner(provider, user_id) do
          Repo.delete(provider)
        end
    end
  end

  # --- User-facing queries ---

  def list_providers(user_id) do
    accessible_ids = Authorization.accessible_entity_ids("llm_provider", user_id)

    LlmProvider
    |> where(
      [p],
      p.user_id == ^user_id or p.instance_wide == true or p.id in subquery(accessible_ids)
    )
    |> order_by([p], asc: p.name)
    |> Repo.all()
  end

  def get_provider(id, user_id) do
    case Repo.get(LlmProvider, id) do
      nil ->
        {:error, :not_found}

      %LlmProvider{user_id: ^user_id} = provider ->
        {:ok, provider}

      %LlmProvider{instance_wide: true} = provider ->
        {:ok, provider}

      %LlmProvider{} = provider ->
        if Authorization.has_access?("llm_provider", provider.id, user_id) do
          {:ok, provider}
        else
          {:error, :not_found}
        end
    end
  end

  def get_provider!(id) do
    Repo.get!(LlmProvider, id)
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

  # --- Private ---

  defp authorize_owner(entity, user_id), do: Authorization.authorize_owner(entity, user_id)
end
