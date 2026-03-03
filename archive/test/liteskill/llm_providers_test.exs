defmodule Liteskill.LlmProvidersTest do
  use Liteskill.DataCase, async: false

  import Ecto.Query

  alias Liteskill.Authorization.EntityAcl
  alias Liteskill.LlmProviders
  alias Liteskill.LlmProviders.LlmProvider
  alias Liteskill.Rbac

  setup do
    # Ensure RBAC system roles exist
    Rbac.ensure_system_roles()

    {:ok, admin} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "admin-#{System.unique_integer([:positive])}@example.com",
        name: "Admin",
        oidc_sub: "admin-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    # Give admin the Instance Admin role (which has "*" permission)
    [admin_role] = Enum.filter(Rbac.list_roles(), &(&1.name == "Instance Admin"))
    {:ok, _} = Rbac.assign_role_to_user(admin.id, admin_role.id)

    {:ok, other} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "other-#{System.unique_integer([:positive])}@example.com",
        name: "Other",
        oidc_sub: "other-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{admin: admin, other: other}
  end

  defp valid_attrs(user_id) do
    %{
      name: "AWS Bedrock US-East",
      provider_type: "amazon_bedrock",
      user_id: user_id
    }
  end

  # --- Changeset ---

  describe "LlmProvider changeset" do
    test "valid changeset with required fields", %{admin: admin} do
      changeset = LlmProvider.changeset(%LlmProvider{}, valid_attrs(admin.id))
      assert changeset.valid?
    end

    test "invalid without name", %{admin: admin} do
      attrs = admin.id |> valid_attrs() |> Map.delete(:name)
      changeset = LlmProvider.changeset(%LlmProvider{}, attrs)
      refute changeset.valid?
    end

    test "invalid without provider_type", %{admin: admin} do
      attrs = admin.id |> valid_attrs() |> Map.delete(:provider_type)
      changeset = LlmProvider.changeset(%LlmProvider{}, attrs)
      refute changeset.valid?
    end

    test "invalid provider_type rejected", %{admin: admin} do
      attrs = admin.id |> valid_attrs() |> Map.put(:provider_type, "invalid_type")
      changeset = LlmProvider.changeset(%LlmProvider{}, attrs)
      refute changeset.valid?
    end

    test "invalid status rejected", %{admin: admin} do
      attrs = admin.id |> valid_attrs() |> Map.put(:status, "deleted")
      changeset = LlmProvider.changeset(%LlmProvider{}, attrs)
      refute changeset.valid?
    end

    test "valid_provider_types includes all ReqLLM providers" do
      types = LlmProvider.valid_provider_types()
      # Dynamically sourced from ReqLLM — includes 50+ providers
      assert length(types) >= 50
      # Key providers present
      assert "amazon_bedrock" in types
      assert "anthropic" in types
      assert "openai" in types
      assert "google" in types
      assert "groq" in types
      assert "azure" in types
      assert "cerebras" in types
      assert "xai" in types
      assert "openrouter" in types
      assert "vllm" in types
      assert "deepseek" in types
    end
  end

  # --- CRUD ---

  describe "create_provider/1" do
    test "creates provider with valid attrs", %{admin: admin} do
      assert {:ok, provider} = LlmProviders.create_provider(valid_attrs(admin.id))
      assert provider.name == "AWS Bedrock US-East"
      assert provider.provider_type == "amazon_bedrock"
      assert provider.status == "active"
      assert provider.instance_wide == false

      # No owner ACL — RBAC handles management, explicit ACLs handle usage
      acl =
        Repo.one(
          from a in EntityAcl,
            where: a.entity_type == "llm_provider" and a.entity_id == ^provider.id
        )

      assert acl == nil
    end

    test "creates provider with all optional fields", %{admin: admin} do
      attrs =
        admin.id
        |> valid_attrs()
        |> Map.merge(%{
          api_key: "secret-api-key",
          provider_config: %{"region" => "us-west-2"},
          instance_wide: true,
          status: "inactive"
        })

      assert {:ok, provider} = LlmProviders.create_provider(attrs)
      assert provider.api_key == "secret-api-key"
      assert provider.provider_config == %{"region" => "us-west-2"}
      assert provider.instance_wide == true
      assert provider.status == "inactive"
    end

    test "fails with invalid attrs", %{admin: admin} do
      attrs = admin.id |> valid_attrs() |> Map.delete(:name)
      assert {:error, _changeset} = LlmProviders.create_provider(attrs)
    end
  end

  describe "update_provider/3" do
    test "admin can update provider", %{admin: admin} do
      {:ok, provider} = LlmProviders.create_provider(valid_attrs(admin.id))

      assert {:ok, updated} =
               LlmProviders.update_provider(provider.id, admin.id, %{name: "Updated Name"})

      assert updated.name == "Updated Name"
    end

    test "non-admin cannot update provider", %{admin: admin, other: other} do
      {:ok, provider} = LlmProviders.create_provider(valid_attrs(admin.id))

      assert {:error, :forbidden} =
               LlmProviders.update_provider(provider.id, other.id, %{name: "Hacked"})
    end

    test "returns not_found for missing provider", %{admin: admin} do
      assert {:error, :not_found} =
               LlmProviders.update_provider(Ecto.UUID.generate(), admin.id, %{name: "X"})
    end
  end

  describe "delete_provider/2" do
    test "admin can delete provider", %{admin: admin} do
      {:ok, provider} = LlmProviders.create_provider(valid_attrs(admin.id))

      assert {:ok, _} = LlmProviders.delete_provider(provider.id, admin.id)
      assert Repo.get(LlmProvider, provider.id) == nil
    end

    test "non-admin cannot delete provider", %{admin: admin, other: other} do
      {:ok, provider} = LlmProviders.create_provider(valid_attrs(admin.id))

      assert {:error, :forbidden} = LlmProviders.delete_provider(provider.id, other.id)
    end

    test "returns not_found for missing provider", %{admin: admin} do
      assert {:error, :not_found} = LlmProviders.delete_provider(Ecto.UUID.generate(), admin.id)
    end
  end

  # --- Queries ---

  describe "list_providers/1" do
    test "returns creator's own providers via ownership", %{admin: admin} do
      {:ok, provider} = LlmProviders.create_provider(valid_attrs(admin.id))

      providers = LlmProviders.list_providers(admin.id)
      assert length(providers) == 1
      assert hd(providers).id == provider.id
    end

    test "returns providers with explicit usage ACL", %{admin: admin, other: other} do
      {:ok, provider} = LlmProviders.create_provider(valid_attrs(admin.id))

      {:ok, _} =
        LlmProviders.grant_usage(provider.id, other.id, admin.id)

      providers = LlmProviders.list_providers(other.id)
      assert length(providers) == 1
      assert hd(providers).id == provider.id
    end

    test "returns instance_wide providers to other users", %{admin: admin, other: other} do
      attrs = admin.id |> valid_attrs() |> Map.put(:instance_wide, true)
      {:ok, _} = LlmProviders.create_provider(attrs)

      providers = LlmProviders.list_providers(other.id)
      assert length(providers) == 1
    end

    test "does not return non-instance_wide providers to other users", %{
      admin: admin,
      other: other
    } do
      {:ok, _} = LlmProviders.create_provider(valid_attrs(admin.id))

      providers = LlmProviders.list_providers(other.id)
      assert providers == []
    end

    test "returns ACL-shared providers", %{admin: admin, other: other} do
      {:ok, provider} = LlmProviders.create_provider(valid_attrs(admin.id))

      {:ok, _} =
        LlmProviders.grant_usage(provider.id, other.id, admin.id)

      providers = LlmProviders.list_providers(other.id)
      assert length(providers) == 1
    end

    test "returns providers ordered by name", %{admin: admin} do
      {:ok, p1} =
        admin.id |> valid_attrs() |> Map.put(:name, "Zzz Provider") |> LlmProviders.create_provider()

      {:ok, p2} =
        admin.id |> valid_attrs() |> Map.put(:name, "Aaa Provider") |> LlmProviders.create_provider()

      {:ok, _} =
        LlmProviders.grant_usage(p1.id, admin.id, admin.id)

      {:ok, _} =
        LlmProviders.grant_usage(p2.id, admin.id, admin.id)

      providers = LlmProviders.list_providers(admin.id)
      assert length(providers) == 2
      assert hd(providers).name == "Aaa Provider"
    end
  end

  describe "get_provider/2" do
    test "creator can get own provider via ownership", %{admin: admin} do
      {:ok, provider} = LlmProviders.create_provider(valid_attrs(admin.id))

      assert {:ok, fetched} = LlmProviders.get_provider(provider.id, admin.id)
      assert fetched.id == provider.id
    end

    test "instance_wide provider accessible to all", %{admin: admin, other: other} do
      attrs = admin.id |> valid_attrs() |> Map.put(:instance_wide, true)
      {:ok, provider} = LlmProviders.create_provider(attrs)

      assert {:ok, _} = LlmProviders.get_provider(provider.id, other.id)
    end

    test "ACL-shared provider accessible", %{admin: admin, other: other} do
      {:ok, provider} = LlmProviders.create_provider(valid_attrs(admin.id))

      {:ok, _} =
        LlmProviders.grant_usage(provider.id, other.id, admin.id)

      assert {:ok, _} = LlmProviders.get_provider(provider.id, other.id)
    end

    test "returns not_found for unauthorized user", %{admin: admin, other: other} do
      {:ok, provider} = LlmProviders.create_provider(valid_attrs(admin.id))

      assert {:error, :not_found} = LlmProviders.get_provider(provider.id, other.id)
    end

    test "returns not_found for missing provider", %{admin: admin} do
      assert {:error, :not_found} = LlmProviders.get_provider(Ecto.UUID.generate(), admin.id)
    end
  end

  describe "get_provider!/1" do
    test "returns provider by id", %{admin: admin} do
      {:ok, provider} = LlmProviders.create_provider(valid_attrs(admin.id))

      fetched = LlmProviders.get_provider!(provider.id)
      assert fetched.id == provider.id
    end
  end

  # --- Environment bootstrap ---

  describe "ensure_env_providers/0" do
    setup do
      original = Application.get_env(:liteskill, Liteskill.LLM, [])

      on_exit(fn ->
        Application.put_env(:liteskill, Liteskill.LLM, original)
      end)

      # Ensure admin user exists
      Liteskill.Accounts.ensure_admin_user()
      admin_email = Liteskill.Accounts.User.admin_email()
      admin = Liteskill.Accounts.get_user_by_email(admin_email)

      %{real_admin: admin}
    end

    test "creates provider when env var config is present", %{real_admin: admin} do
      Application.put_env(:liteskill, Liteskill.LLM,
        bedrock_bearer_token: "test-env-token",
        bedrock_region: "us-west-2"
      )

      assert :ok = LlmProviders.ensure_env_providers()

      providers = LlmProviders.list_providers(admin.id)
      env_provider = Enum.find(providers, &(&1.name == "Bedrock (environment)"))
      assert env_provider
      assert env_provider.provider_type == "amazon_bedrock"
      assert env_provider.api_key == "test-env-token"
      assert env_provider.provider_config == %{"region" => "us-west-2"}
      assert env_provider.instance_wide == true
      assert env_provider.status == "active"
    end

    test "is idempotent — calling twice does not duplicate", %{real_admin: admin} do
      Application.put_env(:liteskill, Liteskill.LLM,
        bedrock_bearer_token: "test-env-token",
        bedrock_region: "us-east-1"
      )

      assert :ok = LlmProviders.ensure_env_providers()
      assert :ok = LlmProviders.ensure_env_providers()

      providers = LlmProviders.list_providers(admin.id)
      env_providers = Enum.filter(providers, &(&1.name == "Bedrock (environment)"))
      assert length(env_providers) == 1
    end

    test "updates credentials on re-boot", %{real_admin: admin} do
      Application.put_env(:liteskill, Liteskill.LLM,
        bedrock_bearer_token: "old-token",
        bedrock_region: "us-east-1"
      )

      assert :ok = LlmProviders.ensure_env_providers()

      Application.put_env(:liteskill, Liteskill.LLM,
        bedrock_bearer_token: "new-token",
        bedrock_region: "eu-west-1"
      )

      assert :ok = LlmProviders.ensure_env_providers()

      providers = LlmProviders.list_providers(admin.id)
      env_provider = Enum.find(providers, &(&1.name == "Bedrock (environment)"))
      assert env_provider.api_key == "new-token"
      assert env_provider.provider_config == %{"region" => "eu-west-1"}
    end

    test "no-op when no env var is set" do
      Application.put_env(:liteskill, Liteskill.LLM, [])

      assert :ok = LlmProviders.ensure_env_providers()
    end
  end

  describe "get_bedrock_credentials/0" do
    test "returns credentials from active instance-wide provider", %{admin: admin} do
      {:ok, _} =
        LlmProviders.create_provider(%{
          name: "Test Bedrock #{System.unique_integer([:positive])}",
          provider_type: "amazon_bedrock",
          api_key: "db-api-key",
          provider_config: %{"region" => "us-west-2"},
          instance_wide: true,
          user_id: admin.id
        })

      creds = LlmProviders.get_bedrock_credentials()
      assert creds.api_key == "db-api-key"
      assert creds.region == "us-west-2"
    end

    test "returns nil when no bedrock provider exists" do
      assert LlmProviders.get_bedrock_credentials() == nil
    end

    test "ignores inactive providers", %{admin: admin} do
      {:ok, _} =
        LlmProviders.create_provider(%{
          name: "Inactive Bedrock #{System.unique_integer([:positive])}",
          provider_type: "amazon_bedrock",
          api_key: "inactive-key",
          provider_config: %{"region" => "us-east-1"},
          instance_wide: true,
          status: "inactive",
          user_id: admin.id
        })

      assert LlmProviders.get_bedrock_credentials() == nil
    end

    test "ignores non-instance-wide providers", %{admin: admin} do
      {:ok, _} =
        LlmProviders.create_provider(%{
          name: "Private Bedrock #{System.unique_integer([:positive])}",
          provider_type: "amazon_bedrock",
          api_key: "private-key",
          provider_config: %{"region" => "us-east-1"},
          instance_wide: false,
          user_id: admin.id
        })

      assert LlmProviders.get_bedrock_credentials() == nil
    end

    test "defaults region to us-east-1 when not in config", %{admin: admin} do
      {:ok, _} =
        LlmProviders.create_provider(%{
          name: "No Region Bedrock #{System.unique_integer([:positive])}",
          provider_type: "amazon_bedrock",
          api_key: "key-no-region",
          provider_config: %{},
          instance_wide: true,
          user_id: admin.id
        })

      creds = LlmProviders.get_bedrock_credentials()
      assert creds.api_key == "key-no-region"
      assert creds.region == "us-east-1"
    end
  end

  # --- Usage grants ---

  describe "grant_usage/3" do
    test "non-admin cannot grant usage", %{admin: admin, other: other} do
      {:ok, provider} = LlmProviders.create_provider(valid_attrs(admin.id))

      assert {:error, :forbidden} = LlmProviders.grant_usage(provider.id, other.id, other.id)
    end
  end

  describe "revoke_usage/3" do
    test "admin can revoke usage", %{admin: admin, other: other} do
      {:ok, provider} = LlmProviders.create_provider(valid_attrs(admin.id))
      {:ok, _} = LlmProviders.grant_usage(provider.id, other.id, admin.id)

      assert {:ok, _} = LlmProviders.revoke_usage(provider.id, other.id, admin.id)
      assert {:error, :not_found} = LlmProviders.get_provider(provider.id, other.id)
    end

    test "returns not_found when no ACL exists", %{admin: admin, other: other} do
      {:ok, provider} = LlmProviders.create_provider(valid_attrs(admin.id))

      assert {:error, :not_found} = LlmProviders.revoke_usage(provider.id, other.id, admin.id)
    end

    test "non-admin cannot revoke usage", %{admin: admin, other: other} do
      {:ok, provider} = LlmProviders.create_provider(valid_attrs(admin.id))

      assert {:error, :forbidden} = LlmProviders.revoke_usage(provider.id, admin.id, other.id)
    end
  end

  # --- Admin helpers ---

  describe "list_all_providers/0" do
    test "returns all providers regardless of user", %{admin: admin} do
      {:ok, _provider} = LlmProviders.create_provider(valid_attrs(admin.id))

      providers = LlmProviders.list_all_providers()
      assert providers != []
    end
  end

  describe "get_provider_for_admin/1" do
    test "returns provider without auth checks", %{admin: admin} do
      {:ok, provider} = LlmProviders.create_provider(valid_attrs(admin.id))

      assert {:ok, fetched} = LlmProviders.get_provider_for_admin(provider.id)
      assert fetched.id == provider.id
    end

    test "returns not_found for missing provider" do
      assert {:error, :not_found} = LlmProviders.get_provider_for_admin(Ecto.UUID.generate())
    end
  end

  # --- Owner-based access ---

  describe "owner can update/delete own provider" do
    test "non-admin owner can update own provider", %{other: other} do
      {:ok, provider} = LlmProviders.create_provider(valid_attrs(other.id))

      assert {:ok, updated} =
               LlmProviders.update_provider(provider.id, other.id, %{name: "Updated"})

      assert updated.name == "Updated"
    end

    test "non-admin owner can delete own provider", %{other: other} do
      {:ok, provider} = LlmProviders.create_provider(valid_attrs(other.id))

      assert {:ok, _} = LlmProviders.delete_provider(provider.id, other.id)
      assert Repo.get(LlmProvider, provider.id) == nil
    end

    test "non-owner non-admin cannot update", %{admin: admin, other: other} do
      {:ok, provider} = LlmProviders.create_provider(valid_attrs(admin.id))

      assert {:error, :forbidden} =
               LlmProviders.update_provider(provider.id, other.id, %{name: "Hacked"})
    end

    test "non-owner non-admin cannot delete", %{admin: admin, other: other} do
      {:ok, provider} = LlmProviders.create_provider(valid_attrs(admin.id))

      assert {:error, :forbidden} = LlmProviders.delete_provider(provider.id, other.id)
    end
  end

  describe "list_owned_providers/1" do
    test "returns only providers owned by user", %{admin: admin, other: other} do
      {:ok, _admin_provider} = LlmProviders.create_provider(valid_attrs(admin.id))

      {:ok, other_provider} =
        other.id |> valid_attrs() |> Map.put(:name, "Other's Provider") |> LlmProviders.create_provider()

      owned = LlmProviders.list_owned_providers(other.id)
      assert length(owned) == 1
      assert hd(owned).id == other_provider.id
    end

    test "returns empty list for user with no providers", %{other: other} do
      assert LlmProviders.list_owned_providers(other.id) == []
    end
  end

  describe "get_provider_for_owner/2" do
    test "returns provider owned by user", %{other: other} do
      {:ok, provider} = LlmProviders.create_provider(valid_attrs(other.id))

      assert {:ok, fetched} = LlmProviders.get_provider_for_owner(provider.id, other.id)
      assert fetched.id == provider.id
    end

    test "returns forbidden for non-owner", %{admin: admin, other: other} do
      {:ok, provider} = LlmProviders.create_provider(valid_attrs(admin.id))

      assert {:error, :forbidden} = LlmProviders.get_provider_for_owner(provider.id, other.id)
    end

    test "returns not_found for missing provider", %{other: other} do
      assert {:error, :not_found} =
               LlmProviders.get_provider_for_owner(Ecto.UUID.generate(), other.id)
    end
  end

  # --- Encrypted fields round-trip ---

  describe "encrypted fields" do
    test "api_key is encrypted and decrypted", %{admin: admin} do
      attrs = admin.id |> valid_attrs() |> Map.put(:api_key, "super-secret-key-123")
      {:ok, provider} = LlmProviders.create_provider(attrs)

      reloaded = Repo.get!(LlmProvider, provider.id)
      assert reloaded.api_key == "super-secret-key-123"
    end

    test "provider_config is encrypted and decrypted", %{admin: admin} do
      config = %{"region" => "eu-west-1", "custom_field" => "value"}
      attrs = admin.id |> valid_attrs() |> Map.put(:provider_config, config)
      {:ok, provider} = LlmProviders.create_provider(attrs)

      reloaded = Repo.get!(LlmProvider, provider.id)
      assert reloaded.provider_config == config
    end
  end
end
