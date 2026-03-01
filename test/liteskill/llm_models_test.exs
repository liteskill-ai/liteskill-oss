defmodule Liteskill.LlmModelsTest do
  use Liteskill.DataCase, async: false

  import Ecto.Query

  alias Liteskill.Authorization.EntityAcl
  alias Liteskill.LlmModels
  alias Liteskill.LlmModels.LlmModel
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

    {:ok, provider} =
      LlmProviders.create_provider(%{
        name: "Test Bedrock",
        provider_type: "amazon_bedrock",
        api_key: "test-key",
        provider_config: %{"region" => "us-east-1"},
        user_id: admin.id
      })

    %{admin: admin, other: other, provider: provider}
  end

  defp valid_attrs(user_id, provider_id) do
    %{
      name: "Claude Sonnet",
      model_id: "us.anthropic.claude-3-5-sonnet-20241022-v2:0",
      provider_id: provider_id,
      user_id: user_id
    }
  end

  # --- Changeset ---

  describe "LlmModel changeset" do
    test "valid changeset with required fields", %{admin: admin, provider: provider} do
      changeset = LlmModel.changeset(%LlmModel{}, valid_attrs(admin.id, provider.id))
      assert changeset.valid?
    end

    test "invalid without name", %{admin: admin, provider: provider} do
      attrs = admin.id |> valid_attrs(provider.id) |> Map.delete(:name)
      changeset = LlmModel.changeset(%LlmModel{}, attrs)
      refute changeset.valid?
    end

    test "invalid without provider_id", %{admin: admin, provider: provider} do
      attrs = admin.id |> valid_attrs(provider.id) |> Map.delete(:provider_id)
      changeset = LlmModel.changeset(%LlmModel{}, attrs)
      refute changeset.valid?
    end

    test "invalid without model_id", %{admin: admin, provider: provider} do
      attrs = admin.id |> valid_attrs(provider.id) |> Map.delete(:model_id)
      changeset = LlmModel.changeset(%LlmModel{}, attrs)
      refute changeset.valid?
    end

    test "invalid model_type rejected", %{admin: admin, provider: provider} do
      attrs = admin.id |> valid_attrs(provider.id) |> Map.put(:model_type, "invalid_type")
      changeset = LlmModel.changeset(%LlmModel{}, attrs)
      refute changeset.valid?
    end

    test "invalid status rejected", %{admin: admin, provider: provider} do
      attrs = admin.id |> valid_attrs(provider.id) |> Map.put(:status, "deleted")
      changeset = LlmModel.changeset(%LlmModel{}, attrs)
      refute changeset.valid?
    end

    test "valid_model_types returns all supported types" do
      types = LlmModel.valid_model_types()
      assert "inference" in types
      assert "embedding" in types
      assert "rerank" in types
    end
  end

  # --- CRUD ---

  describe "create_model/1" do
    test "creates model with valid attrs", %{admin: admin, provider: provider} do
      assert {:ok, model} = LlmModels.create_model(valid_attrs(admin.id, provider.id))
      assert model.name == "Claude Sonnet"
      assert model.provider_id == provider.id
      assert model.provider.name == "Test Bedrock"
      assert model.status == "active"
      assert model.instance_wide == false
      assert model.model_type == "inference"

      # No owner ACL — RBAC handles management, explicit ACLs handle usage
      acl =
        Repo.one(from a in EntityAcl, where: a.entity_type == "llm_model" and a.entity_id == ^model.id)

      assert acl == nil
    end

    test "creates model with all optional fields", %{admin: admin, provider: provider} do
      attrs =
        admin.id
        |> valid_attrs(provider.id)
        |> Map.merge(%{
          model_config: %{"max_tokens" => 4096},
          model_type: "embedding",
          instance_wide: true,
          status: "inactive"
        })

      assert {:ok, model} = LlmModels.create_model(attrs)
      assert model.model_config == %{"max_tokens" => 4096}
      assert model.model_type == "embedding"
      assert model.instance_wide == true
      assert model.status == "inactive"
    end

    test "fails with invalid attrs", %{admin: admin, provider: provider} do
      attrs = admin.id |> valid_attrs(provider.id) |> Map.delete(:name)
      assert {:error, _changeset} = LlmModels.create_model(attrs)
    end
  end

  describe "update_model/3" do
    test "admin can update model", %{admin: admin, provider: provider} do
      {:ok, model} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      assert {:ok, updated} = LlmModels.update_model(model.id, admin.id, %{name: "Updated Name"})
      assert updated.name == "Updated Name"
      assert updated.provider.name == "Test Bedrock"
    end

    test "non-admin cannot update model", %{admin: admin, other: other, provider: provider} do
      {:ok, model} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      assert {:error, :forbidden} = LlmModels.update_model(model.id, other.id, %{name: "Hacked"})
    end

    test "returns not_found for missing model", %{admin: admin} do
      assert {:error, :not_found} =
               LlmModels.update_model(Ecto.UUID.generate(), admin.id, %{name: "X"})
    end

    test "returns error on invalid update", %{admin: admin, provider: provider} do
      {:ok, model} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      assert {:error, changeset} =
               LlmModels.update_model(model.id, admin.id, %{model_type: "invalid"})

      refute changeset.valid?
    end
  end

  describe "delete_model/2" do
    test "admin can delete model", %{admin: admin, provider: provider} do
      {:ok, model} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      assert {:ok, _} = LlmModels.delete_model(model.id, admin.id)
      assert Repo.get(LlmModel, model.id) == nil
    end

    test "non-admin cannot delete model", %{admin: admin, other: other, provider: provider} do
      {:ok, model} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      assert {:error, :forbidden} = LlmModels.delete_model(model.id, other.id)
    end

    test "returns not_found for missing model", %{admin: admin} do
      assert {:error, :not_found} = LlmModels.delete_model(Ecto.UUID.generate(), admin.id)
    end
  end

  # --- Queries ---

  describe "list_models/1" do
    test "returns creator's own models via ownership", %{
      admin: admin,
      provider: provider
    } do
      {:ok, model} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      models = LlmModels.list_models(admin.id)
      assert length(models) == 1
      assert hd(models).id == model.id
      assert hd(models).provider.name == "Test Bedrock"
    end

    test "returns models with explicit usage ACL", %{
      admin: admin,
      other: other,
      provider: provider
    } do
      {:ok, model} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      {:ok, _} = LlmModels.grant_usage(model.id, other.id, admin.id)

      models = LlmModels.list_models(other.id)
      assert length(models) == 1
      assert hd(models).id == model.id
      assert hd(models).provider.name == "Test Bedrock"
    end

    test "returns instance_wide models to other users", %{
      admin: admin,
      other: other,
      provider: provider
    } do
      attrs = admin.id |> valid_attrs(provider.id) |> Map.put(:instance_wide, true)
      {:ok, _model} = LlmModels.create_model(attrs)

      models = LlmModels.list_models(other.id)
      assert length(models) == 1
    end

    test "does not return non-instance_wide models to other users", %{
      admin: admin,
      other: other,
      provider: provider
    } do
      {:ok, _model} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      models = LlmModels.list_models(other.id)
      assert models == []
    end

    test "returns ACL-shared models", %{admin: admin, other: other, provider: provider} do
      {:ok, model} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      {:ok, _} = LlmModels.grant_usage(model.id, other.id, admin.id)

      models = LlmModels.list_models(other.id)
      assert length(models) == 1
    end

    test "returns models ordered by name", %{admin: admin, provider: provider} do
      {:ok, m1} =
        admin.id |> valid_attrs(provider.id) |> Map.put(:name, "Zzz Model") |> LlmModels.create_model()

      {:ok, m2} =
        admin.id
        |> valid_attrs(provider.id)
        |> Map.merge(%{name: "Aaa Model", model_id: "aaa-model"})
        |> LlmModels.create_model()

      # Grant usage access so they appear in the list
      {:ok, _} = LlmModels.grant_usage(m1.id, admin.id, admin.id)
      {:ok, _} = LlmModels.grant_usage(m2.id, admin.id, admin.id)

      models = LlmModels.list_models(admin.id)
      assert length(models) == 2
      assert hd(models).name == "Aaa Model"
    end
  end

  describe "list_active_models/1" do
    test "filters out inactive models", %{admin: admin, provider: provider} do
      {:ok, active} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      {:ok, _inactive} =
        admin.id
        |> valid_attrs(provider.id)
        |> Map.merge(%{status: "inactive", model_id: "inactive-model"})
        |> LlmModels.create_model()

      {:ok, _} = LlmModels.grant_usage(active.id, admin.id, admin.id)

      models = LlmModels.list_active_models(admin.id)
      assert length(models) == 1
      assert hd(models).status == "active"
    end

    test "returns creator's own active models via ownership", %{
      admin: admin,
      provider: provider
    } do
      {:ok, model} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      models = LlmModels.list_active_models(admin.id)
      assert length(models) == 1
      assert hd(models).id == model.id
    end

    test "filters by model_type", %{admin: admin, provider: provider} do
      {:ok, inference} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      {:ok, embedding} =
        admin.id
        |> valid_attrs(provider.id)
        |> Map.merge(%{model_type: "embedding", model_id: "embed-model"})
        |> LlmModels.create_model()

      # Grant usage access
      {:ok, _} = LlmModels.grant_usage(inference.id, admin.id, admin.id)
      {:ok, _} = LlmModels.grant_usage(embedding.id, admin.id, admin.id)

      inference_models = LlmModels.list_active_models(admin.id, model_type: "inference")
      assert length(inference_models) == 1
      assert hd(inference_models).model_type == "inference"

      embedding_models = LlmModels.list_active_models(admin.id, model_type: "embedding")
      assert length(embedding_models) == 1
      assert hd(embedding_models).model_type == "embedding"
    end

    test "returns all types when model_type not specified", %{
      admin: admin,
      provider: provider
    } do
      {:ok, inference} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      {:ok, embedding} =
        admin.id
        |> valid_attrs(provider.id)
        |> Map.merge(%{model_type: "embedding", model_id: "embed-model"})
        |> LlmModels.create_model()

      {:ok, _} = LlmModels.grant_usage(inference.id, admin.id, admin.id)
      {:ok, _} = LlmModels.grant_usage(embedding.id, admin.id, admin.id)

      models = LlmModels.list_active_models(admin.id)
      assert length(models) == 2
    end

    test "filters out models whose provider is inactive", %{admin: admin} do
      {:ok, inactive_provider} =
        LlmProviders.create_provider(%{
          name: "Inactive Provider",
          provider_type: "openai",
          status: "inactive",
          user_id: admin.id
        })

      {:ok, model_on_inactive} =
        LlmModels.create_model(%{
          name: "Model on Inactive",
          model_id: "gpt-4o-inactive",
          provider_id: inactive_provider.id,
          user_id: admin.id,
          status: "active"
        })

      {:ok, active_provider} =
        LlmProviders.create_provider(%{
          name: "Active Provider",
          provider_type: "anthropic",
          user_id: admin.id
        })

      {:ok, model_on_active} =
        LlmModels.create_model(%{
          name: "Model on Active",
          model_id: "claude-active",
          provider_id: active_provider.id,
          user_id: admin.id,
          status: "active"
        })

      # Grant usage for both
      {:ok, _} = LlmModels.grant_usage(model_on_inactive.id, admin.id, admin.id)
      {:ok, _} = LlmModels.grant_usage(model_on_active.id, admin.id, admin.id)

      models = LlmModels.list_active_models(admin.id)
      assert length(models) == 1
      assert hd(models).name == "Model on Active"
    end
  end

  describe "get_model/2" do
    test "creator can get own model via ownership", %{
      admin: admin,
      provider: provider
    } do
      {:ok, model} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      assert {:ok, fetched} = LlmModels.get_model(model.id, admin.id)
      assert fetched.id == model.id
      assert fetched.provider.name == "Test Bedrock"
    end

    test "instance_wide model accessible to all", %{
      admin: admin,
      other: other,
      provider: provider
    } do
      attrs = admin.id |> valid_attrs(provider.id) |> Map.put(:instance_wide, true)
      {:ok, model} = LlmModels.create_model(attrs)

      assert {:ok, _} = LlmModels.get_model(model.id, other.id)
    end

    test "ACL-shared model accessible", %{admin: admin, other: other, provider: provider} do
      {:ok, model} = LlmModels.create_model(valid_attrs(admin.id, provider.id))
      {:ok, _} = LlmModels.grant_usage(model.id, other.id, admin.id)

      assert {:ok, _} = LlmModels.get_model(model.id, other.id)
    end

    test "returns not_found for unauthorized user", %{
      admin: admin,
      other: other,
      provider: provider
    } do
      {:ok, model} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      assert {:error, :not_found} = LlmModels.get_model(model.id, other.id)
    end

    test "returns not_found for missing model", %{admin: admin} do
      assert {:error, :not_found} = LlmModels.get_model(Ecto.UUID.generate(), admin.id)
    end
  end

  describe "get_model!/1" do
    test "returns model by id with preloaded provider", %{admin: admin, provider: provider} do
      {:ok, model} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      fetched = LlmModels.get_model!(model.id)
      assert fetched.id == model.id
      assert fetched.provider.name == "Test Bedrock"
    end
  end

  # --- Provider Options ---

  describe "build_provider_options/1" do
    test "amazon_bedrock with region and api_key" do
      provider = %LlmProvider{
        provider_type: "amazon_bedrock",
        api_key: "my-token",
        provider_config: %{"region" => "us-west-2"}
      }

      model = %LlmModel{
        model_id: "us.anthropic.claude-3-5-sonnet-20241022-v2:0",
        provider: provider
      }

      {model_spec, opts} = LlmModels.build_provider_options(model)

      assert model_spec == %{
               id: "us.anthropic.claude-3-5-sonnet-20241022-v2:0",
               provider: :amazon_bedrock
             }

      assert opts |> Keyword.get(:provider_options) |> Keyword.get(:region) == "us-west-2"
      assert opts |> Keyword.get(:provider_options) |> Keyword.get(:use_converse) == true
      assert Keyword.get(opts, :api_key) == "my-token"
    end

    test "amazon_bedrock defaults region" do
      provider = %LlmProvider{
        provider_type: "amazon_bedrock",
        api_key: nil,
        provider_config: %{}
      }

      model = %LlmModel{model_id: "model-id", provider: provider}

      {_model_spec, opts} = LlmModels.build_provider_options(model)
      assert opts |> Keyword.get(:provider_options) |> Keyword.get(:region) == "us-east-1"
    end

    test "amazon_bedrock handles nil provider_config" do
      provider = %LlmProvider{
        provider_type: "amazon_bedrock",
        api_key: nil,
        provider_config: nil
      }

      model = %LlmModel{model_id: "model-id", provider: provider}

      {_model_spec, opts} = LlmModels.build_provider_options(model)
      assert opts |> Keyword.get(:provider_options) |> Keyword.get(:region) == "us-east-1"
    end

    test "azure with deployment config" do
      provider = %LlmProvider{
        provider_type: "azure",
        api_key: "az-key",
        provider_config: %{
          "resource_name" => "my-resource",
          "deployment_id" => "gpt4o-deploy",
          "api_version" => "2024-02-15"
        }
      }

      model = %LlmModel{model_id: "gpt-4o", provider: provider}

      {model_spec, opts} = LlmModels.build_provider_options(model)

      assert model_spec == %{id: "gpt-4o", provider: :azure}
      provider_opts = Keyword.get(opts, :provider_options)
      assert Keyword.get(provider_opts, :resource_name) == "my-resource"
      assert Keyword.get(provider_opts, :deployment_id) == "gpt4o-deploy"
      assert Keyword.get(provider_opts, :api_version) == "2024-02-15"
      assert Keyword.get(opts, :api_key) == "az-key"
    end

    test "azure omits nil config values" do
      provider = %LlmProvider{
        provider_type: "azure",
        api_key: "az-key",
        provider_config: %{"resource_name" => "my-resource"}
      }

      model = %LlmModel{model_id: "gpt-4o", provider: provider}

      {_model_spec, opts} = LlmModels.build_provider_options(model)
      provider_opts = Keyword.get(opts, :provider_options)
      refute Keyword.has_key?(provider_opts, :deployment_id)
      refute Keyword.has_key?(provider_opts, :api_version)
    end

    test "anthropic with api_key" do
      provider = %LlmProvider{
        provider_type: "anthropic",
        api_key: "sk-ant-xxx",
        provider_config: %{}
      }

      model = %LlmModel{model_id: "claude-3-5-sonnet", provider: provider}

      {model_spec, opts} = LlmModels.build_provider_options(model)

      assert model_spec == %{id: "claude-3-5-sonnet", provider: :anthropic}
      assert Keyword.get(opts, :provider_options) == []
      assert Keyword.get(opts, :api_key) == "sk-ant-xxx"
    end

    test "openai with api_key" do
      provider = %LlmProvider{
        provider_type: "openai",
        api_key: "sk-xxx",
        provider_config: %{}
      }

      model = %LlmModel{model_id: "gpt-4o", provider: provider}

      {model_spec, opts} = LlmModels.build_provider_options(model)

      assert model_spec == %{id: "gpt-4o", provider: :openai}
      assert Keyword.get(opts, :provider_options) == []
      assert Keyword.get(opts, :api_key) == "sk-xxx"
    end

    test "provider without api_key" do
      provider = %LlmProvider{
        provider_type: "groq",
        api_key: nil,
        provider_config: %{}
      }

      model = %LlmModel{model_id: "llama-3", provider: provider}

      {model_spec, opts} = LlmModels.build_provider_options(model)

      assert model_spec == %{id: "llama-3", provider: :groq}
      assert Keyword.get(opts, :provider_options) == []
    end

    test "base_url extracted as top-level option" do
      provider = %LlmProvider{
        provider_type: "openai",
        api_key: "sk-xxx",
        provider_config: %{"base_url" => "http://litellm:4000/v1"}
      }

      model = %LlmModel{model_id: "gpt-4o", provider: provider}

      {_model_spec, opts} = LlmModels.build_provider_options(model)

      assert Keyword.get(opts, :base_url) == "http://litellm:4000/v1"
      assert Keyword.get(opts, :api_key) == "sk-xxx"
      provider_opts = Keyword.get(opts, :provider_options)
      refute Keyword.has_key?(provider_opts, :base_url)
    end

    test "no base_url when not in config" do
      provider = %LlmProvider{
        provider_type: "anthropic",
        api_key: "sk-ant-xxx",
        provider_config: %{}
      }

      model = %LlmModel{model_id: "claude-3-5-sonnet", provider: provider}

      {_model_spec, opts} = LlmModels.build_provider_options(model)

      refute Keyword.has_key?(opts, :base_url)
    end

    test "generic provider config entries passed as provider_options" do
      provider = %LlmProvider{
        provider_type: "google_vertex",
        api_key: nil,
        provider_config: %{"project_id" => "my-project", "location" => "us-central1"}
      }

      model = %LlmModel{model_id: "gemini-pro", provider: provider}

      {model_spec, opts} = LlmModels.build_provider_options(model)

      assert model_spec == %{id: "gemini-pro", provider: :google_vertex}
      provider_opts = Keyword.get(opts, :provider_options)
      assert Keyword.get(provider_opts, :project_id) == "my-project"
      assert Keyword.get(provider_opts, :location) == "us-central1"
    end

    test "base_url with bedrock still uses special handling" do
      provider = %LlmProvider{
        provider_type: "amazon_bedrock",
        api_key: "token",
        provider_config: %{"region" => "eu-west-1", "base_url" => "http://custom:8080"}
      }

      model = %LlmModel{model_id: "anthropic.claude-3", provider: provider}

      {_model_spec, opts} = LlmModels.build_provider_options(model)

      assert Keyword.get(opts, :base_url) == "http://custom:8080"
      assert Keyword.get(opts, :api_key) == "token"
      provider_opts = Keyword.get(opts, :provider_options)
      assert Keyword.get(provider_opts, :region) == "eu-west-1"
      assert Keyword.get(provider_opts, :use_converse) == true
    end

    test "unknown config keys are skipped gracefully" do
      provider = %LlmProvider{
        provider_type: "openai",
        api_key: "sk-xxx",
        provider_config: %{"totally_unknown_key_xyz" => "value"}
      }

      model = %LlmModel{model_id: "gpt-4o", provider: provider}

      {_model_spec, opts} = LlmModels.build_provider_options(model)

      assert Keyword.get(opts, :api_key) == "sk-xxx"
      provider_opts = Keyword.get(opts, :provider_options)
      assert provider_opts == []
    end
  end

  describe "build_provider_options/2 — prompt caching" do
    test "switches to native API for Anthropic on Bedrock" do
      provider = %LlmProvider{
        provider_type: "amazon_bedrock",
        api_key: nil,
        provider_config: %{"region" => "us-east-1"}
      }

      model = %LlmModel{
        model_id: "us.anthropic.claude-3-5-sonnet-20241022-v2:0",
        provider: provider
      }

      {_model_spec, opts} = LlmModels.build_provider_options(model, enable_caching: true)
      provider_opts = Keyword.get(opts, :provider_options)

      # Switches to native Anthropic API (not Converse) for caching support.
      # Actual anthropic_prompt_cache is set by LlmGenerate based on tool count.
      assert Keyword.get(provider_opts, :use_converse) == false
      refute Keyword.has_key?(provider_opts, :anthropic_prompt_cache)
    end

    test "does not switch API for non-Anthropic Bedrock models" do
      provider = %LlmProvider{
        provider_type: "amazon_bedrock",
        api_key: nil,
        provider_config: %{"region" => "us-east-1"}
      }

      model = %LlmModel{
        model_id: "amazon.titan-text-express-v1",
        provider: provider
      }

      {_model_spec, opts} = LlmModels.build_provider_options(model, enable_caching: true)
      provider_opts = Keyword.get(opts, :provider_options)

      assert Keyword.get(provider_opts, :use_converse) == true
    end

    test "does not switch API for non-Bedrock providers" do
      provider = %LlmProvider{
        provider_type: "anthropic",
        api_key: "sk-ant-xxx",
        provider_config: %{}
      }

      model = %LlmModel{
        model_id: "claude-3-5-sonnet",
        provider: provider
      }

      {_model_spec, opts} = LlmModels.build_provider_options(model, enable_caching: true)
      provider_opts = Keyword.get(opts, :provider_options)

      refute Keyword.has_key?(provider_opts, :use_converse)
    end

    test "does not switch API when enable_caching is false" do
      provider = %LlmProvider{
        provider_type: "amazon_bedrock",
        api_key: nil,
        provider_config: %{"region" => "us-east-1"}
      }

      model = %LlmModel{
        model_id: "us.anthropic.claude-3-5-sonnet-20241022-v2:0",
        provider: provider
      }

      {_model_spec, opts} = LlmModels.build_provider_options(model, enable_caching: false)
      provider_opts = Keyword.get(opts, :provider_options)

      assert Keyword.get(provider_opts, :use_converse) == true
    end

    test "backward compat — 1-arity call works unchanged" do
      provider = %LlmProvider{
        provider_type: "amazon_bedrock",
        api_key: nil,
        provider_config: %{"region" => "us-east-1"}
      }

      model = %LlmModel{
        model_id: "us.anthropic.claude-3-5-sonnet-20241022-v2:0",
        provider: provider
      }

      {_model_spec, opts} = LlmModels.build_provider_options(model)
      provider_opts = Keyword.get(opts, :provider_options)

      # No caching by default
      assert Keyword.get(provider_opts, :use_converse) == true
    end
  end

  # --- LLM.available_models/1 integration ---

  describe "LLM.available_models/1" do
    test "returns DB models when they exist", %{admin: admin, provider: provider} do
      {:ok, model} = LlmModels.create_model(valid_attrs(admin.id, provider.id))
      {:ok, _} = LlmModels.grant_usage(model.id, admin.id, admin.id)

      result = Liteskill.LLM.available_models(admin.id)
      assert is_list(result)
      assert length(result) == 1
      assert %LlmModel{} = hd(result)
    end

    test "returns empty list when no DB models configured", %{other: other} do
      result = Liteskill.LLM.available_models(other.id)
      assert result == []
    end

    test "only returns inference models", %{admin: admin, provider: provider} do
      {:ok, inference} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      {:ok, embedding} =
        admin.id
        |> valid_attrs(provider.id)
        |> Map.merge(%{model_type: "embedding", model_id: "embed-model"})
        |> LlmModels.create_model()

      {:ok, _} = LlmModels.grant_usage(inference.id, admin.id, admin.id)
      {:ok, _} = LlmModels.grant_usage(embedding.id, admin.id, admin.id)

      result = Liteskill.LLM.available_models(admin.id)
      assert length(result) == 1
      assert hd(result).model_type == "inference"
    end
  end

  # --- Usage grants ---

  describe "grant_usage/3" do
    test "non-admin cannot grant usage", %{admin: admin, other: other, provider: provider} do
      {:ok, model} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      assert {:error, :forbidden} = LlmModels.grant_usage(model.id, other.id, other.id)
    end
  end

  describe "revoke_usage/3" do
    test "admin can revoke usage", %{admin: admin, other: other, provider: provider} do
      {:ok, model} = LlmModels.create_model(valid_attrs(admin.id, provider.id))
      {:ok, _} = LlmModels.grant_usage(model.id, other.id, admin.id)

      assert {:ok, _} = LlmModels.revoke_usage(model.id, other.id, admin.id)
      assert {:error, :not_found} = LlmModels.get_model(model.id, other.id)
    end

    test "returns not_found when no ACL exists", %{admin: admin, other: other, provider: provider} do
      {:ok, model} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      assert {:error, :not_found} = LlmModels.revoke_usage(model.id, other.id, admin.id)
    end

    test "non-admin cannot revoke usage", %{admin: admin, other: other, provider: provider} do
      {:ok, model} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      assert {:error, :forbidden} = LlmModels.revoke_usage(model.id, admin.id, other.id)
    end
  end

  # --- Admin helpers ---

  describe "list_all_models/0" do
    test "returns all models regardless of user", %{admin: admin, provider: provider} do
      {:ok, _model} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      models = LlmModels.list_all_models()
      assert models != []
      assert Enum.all?(models, &(&1.provider != nil))
    end
  end

  describe "list_all_active_models/1" do
    test "returns all active models without user filtering", %{admin: admin, provider: provider} do
      {:ok, _active} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      {:ok, _inactive} =
        admin.id
        |> valid_attrs(provider.id)
        |> Map.merge(%{status: "inactive", model_id: "inactive-model"})
        |> LlmModels.create_model()

      models = LlmModels.list_all_active_models()
      active_names = Enum.map(models, & &1.name)
      assert "Claude Sonnet" in active_names
    end

    test "filters by model_type", %{admin: admin, provider: provider} do
      {:ok, _inference} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      {:ok, _embedding} =
        admin.id
        |> valid_attrs(provider.id)
        |> Map.merge(%{model_type: "embedding", model_id: "embed-model"})
        |> LlmModels.create_model()

      models = LlmModels.list_all_active_models(model_type: "embedding")
      assert Enum.all?(models, &(&1.model_type == "embedding"))
    end
  end

  describe "get_model_for_admin/1" do
    test "returns model without auth checks", %{admin: admin, provider: provider} do
      {:ok, model} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      assert {:ok, fetched} = LlmModels.get_model_for_admin(model.id)
      assert fetched.id == model.id
      assert fetched.provider.name == "Test Bedrock"
    end

    test "returns not_found for missing model" do
      assert {:error, :not_found} = LlmModels.get_model_for_admin(Ecto.UUID.generate())
    end
  end

  # --- Owner-based access ---

  describe "provider ownership validation" do
    test "user can create model on own provider", %{other: other} do
      {:ok, other_provider} =
        LlmProviders.create_provider(%{
          name: "Other's Provider",
          provider_type: "openai",
          user_id: other.id
        })

      assert {:ok, model} =
               LlmModels.create_model(valid_attrs(other.id, other_provider.id))

      assert model.provider_id == other_provider.id
    end

    test "user cannot create model on another user's provider", %{admin: admin, other: other} do
      # admin owns the default provider
      {:ok, admin_provider} =
        LlmProviders.create_provider(%{
          name: "Admin Provider",
          provider_type: "openai",
          user_id: admin.id
        })

      assert {:error, :provider_not_owned} =
               LlmModels.create_model(valid_attrs(other.id, admin_provider.id))
    end

    test "admin can create model on any provider", %{admin: admin, other: other} do
      {:ok, other_provider} =
        LlmProviders.create_provider(%{
          name: "Other's Provider",
          provider_type: "openai",
          user_id: other.id
        })

      assert {:ok, _model} =
               LlmModels.create_model(valid_attrs(admin.id, other_provider.id))
    end
  end

  describe "owner can update/delete own model" do
    test "non-admin owner can update own model", %{other: other} do
      {:ok, other_provider} =
        LlmProviders.create_provider(%{
          name: "Other's Provider",
          provider_type: "openai",
          user_id: other.id
        })

      {:ok, model} = LlmModels.create_model(valid_attrs(other.id, other_provider.id))

      assert {:ok, updated} = LlmModels.update_model(model.id, other.id, %{name: "Updated"})
      assert updated.name == "Updated"
    end

    test "non-admin owner can delete own model", %{other: other} do
      {:ok, other_provider} =
        LlmProviders.create_provider(%{
          name: "Other's Provider",
          provider_type: "openai",
          user_id: other.id
        })

      {:ok, model} = LlmModels.create_model(valid_attrs(other.id, other_provider.id))

      assert {:ok, _} = LlmModels.delete_model(model.id, other.id)
      assert Repo.get(LlmModel, model.id) == nil
    end

    test "non-owner non-admin cannot update", %{admin: admin, other: other, provider: provider} do
      {:ok, model} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      assert {:error, :forbidden} =
               LlmModels.update_model(model.id, other.id, %{name: "Hacked"})
    end

    test "non-owner non-admin cannot delete", %{admin: admin, other: other, provider: provider} do
      {:ok, model} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      assert {:error, :forbidden} = LlmModels.delete_model(model.id, other.id)
    end
  end

  describe "list_owned_models/1" do
    test "returns only models owned by user", %{admin: admin, other: other, provider: provider} do
      {:ok, _admin_model} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      {:ok, other_provider} =
        LlmProviders.create_provider(%{
          name: "Other's Provider",
          provider_type: "openai",
          user_id: other.id
        })

      {:ok, other_model} =
        other.id
        |> valid_attrs(other_provider.id)
        |> Map.put(:name, "Other's Model")
        |> LlmModels.create_model()

      owned = LlmModels.list_owned_models(other.id)
      assert length(owned) == 1
      assert hd(owned).id == other_model.id
      assert hd(owned).provider.name == "Other's Provider"
    end

    test "returns empty list for user with no models", %{other: other} do
      assert LlmModels.list_owned_models(other.id) == []
    end
  end

  describe "get_model_for_owner/2" do
    test "returns model owned by user", %{other: other} do
      {:ok, other_provider} =
        LlmProviders.create_provider(%{
          name: "Other's Provider",
          provider_type: "openai",
          user_id: other.id
        })

      {:ok, model} = LlmModels.create_model(valid_attrs(other.id, other_provider.id))

      assert {:ok, fetched} = LlmModels.get_model_for_owner(model.id, other.id)
      assert fetched.id == model.id
      assert fetched.provider.name == "Other's Provider"
    end

    test "returns forbidden for non-owner", %{admin: admin, other: other, provider: provider} do
      {:ok, model} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      assert {:error, :forbidden} = LlmModels.get_model_for_owner(model.id, other.id)
    end

    test "returns not_found for missing model", %{other: other} do
      assert {:error, :not_found} =
               LlmModels.get_model_for_owner(Ecto.UUID.generate(), other.id)
    end
  end

  # --- Encrypted fields round-trip ---

  describe "encrypted fields" do
    test "model_config is encrypted and decrypted", %{admin: admin, provider: provider} do
      config = %{"max_tokens" => 4096, "temperature" => 0.7}

      attrs = admin.id |> valid_attrs(provider.id) |> Map.put(:model_config, config)
      {:ok, model} = LlmModels.create_model(attrs)

      reloaded = Repo.get!(LlmModel, model.id)
      assert reloaded.model_config == config
    end
  end

  describe "validate_provider_ownership edge cases" do
    test "allows nil provider_id to pass validation (changeset catches it)", %{admin: admin} do
      # nil provider_id is allowed by validate_provider_ownership; changeset validation catches it
      result =
        LlmModels.create_model(%{
          name: "No Provider",
          model_id: "no-provider-model",
          user_id: admin.id,
          instance_wide: true
        })

      assert {:error, %Ecto.Changeset{}} = result
    end

    test "allows nil user_id to pass provider validation", %{provider: provider} do
      # nil user_id passes validate_provider_ownership but fails RBAC
      result =
        LlmModels.create_model(%{
          name: "No User",
          model_id: "no-user-model",
          provider_id: provider.id,
          instance_wide: true
        })

      assert {:error, _} = result
    end

    test "nonexistent provider_id passes validation but fails FK constraint", %{admin: admin} do
      result =
        LlmModels.create_model(%{
          name: "Bad Provider",
          model_id: "bad-provider-model",
          provider_id: Ecto.UUID.generate(),
          user_id: admin.id,
          instance_wide: true
        })

      assert {:error, _} = result
    end
  end
end
