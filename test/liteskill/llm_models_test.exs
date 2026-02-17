defmodule Liteskill.LlmModelsTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Authorization
  alias Liteskill.Authorization.EntityAcl
  alias Liteskill.LlmModels
  alias Liteskill.LlmModels.LlmModel
  alias Liteskill.LlmProviders
  alias Liteskill.LlmProviders.LlmProvider

  import Ecto.Query

  setup do
    {:ok, admin} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "admin-#{System.unique_integer([:positive])}@example.com",
        name: "Admin",
        oidc_sub: "admin-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

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
      attrs = valid_attrs(admin.id, provider.id) |> Map.delete(:name)
      changeset = LlmModel.changeset(%LlmModel{}, attrs)
      refute changeset.valid?
    end

    test "invalid without provider_id", %{admin: admin, provider: provider} do
      attrs = valid_attrs(admin.id, provider.id) |> Map.delete(:provider_id)
      changeset = LlmModel.changeset(%LlmModel{}, attrs)
      refute changeset.valid?
    end

    test "invalid without model_id", %{admin: admin, provider: provider} do
      attrs = valid_attrs(admin.id, provider.id) |> Map.delete(:model_id)
      changeset = LlmModel.changeset(%LlmModel{}, attrs)
      refute changeset.valid?
    end

    test "invalid model_type rejected", %{admin: admin, provider: provider} do
      attrs = valid_attrs(admin.id, provider.id) |> Map.put(:model_type, "invalid_type")
      changeset = LlmModel.changeset(%LlmModel{}, attrs)
      refute changeset.valid?
    end

    test "invalid status rejected", %{admin: admin, provider: provider} do
      attrs = valid_attrs(admin.id, provider.id) |> Map.put(:status, "deleted")
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
    test "creates model with valid attrs and owner ACL", %{admin: admin, provider: provider} do
      assert {:ok, model} = LlmModels.create_model(valid_attrs(admin.id, provider.id))
      assert model.name == "Claude Sonnet"
      assert model.provider_id == provider.id
      assert model.provider.name == "Test Bedrock"
      assert model.status == "active"
      assert model.instance_wide == false
      assert model.model_type == "inference"

      acl =
        Repo.one(
          from a in EntityAcl, where: a.entity_type == "llm_model" and a.entity_id == ^model.id
        )

      assert acl.user_id == admin.id
      assert acl.role == "owner"
    end

    test "creates model with all optional fields", %{admin: admin, provider: provider} do
      attrs =
        valid_attrs(admin.id, provider.id)
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
      attrs = valid_attrs(admin.id, provider.id) |> Map.delete(:name)
      assert {:error, _changeset} = LlmModels.create_model(attrs)
    end
  end

  describe "update_model/3" do
    test "owner can update model", %{admin: admin, provider: provider} do
      {:ok, model} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      assert {:ok, updated} = LlmModels.update_model(model.id, admin.id, %{name: "Updated Name"})
      assert updated.name == "Updated Name"
      assert updated.provider.name == "Test Bedrock"
    end

    test "non-owner cannot update model", %{admin: admin, other: other, provider: provider} do
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
    test "owner can delete model", %{admin: admin, provider: provider} do
      {:ok, model} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      assert {:ok, _} = LlmModels.delete_model(model.id, admin.id)
      assert Repo.get(LlmModel, model.id) == nil
    end

    test "non-owner cannot delete model", %{admin: admin, other: other, provider: provider} do
      {:ok, model} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      assert {:error, :forbidden} = LlmModels.delete_model(model.id, other.id)
    end

    test "returns not_found for missing model", %{admin: admin} do
      assert {:error, :not_found} = LlmModels.delete_model(Ecto.UUID.generate(), admin.id)
    end
  end

  # --- Queries ---

  describe "list_models/1" do
    test "returns own models with preloaded provider", %{admin: admin, provider: provider} do
      {:ok, model} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      models = LlmModels.list_models(admin.id)
      assert length(models) == 1
      assert hd(models).id == model.id
      assert hd(models).provider.name == "Test Bedrock"
    end

    test "returns instance_wide models to other users", %{
      admin: admin,
      other: other,
      provider: provider
    } do
      attrs = valid_attrs(admin.id, provider.id) |> Map.put(:instance_wide, true)
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

      {:ok, _} = Authorization.grant_access("llm_model", model.id, admin.id, other.id, "viewer")

      models = LlmModels.list_models(other.id)
      assert length(models) == 1
    end

    test "returns models ordered by name", %{admin: admin, provider: provider} do
      {:ok, _} =
        LlmModels.create_model(valid_attrs(admin.id, provider.id) |> Map.put(:name, "Zzz Model"))

      {:ok, _} =
        LlmModels.create_model(
          valid_attrs(admin.id, provider.id)
          |> Map.merge(%{name: "Aaa Model", model_id: "aaa-model"})
        )

      models = LlmModels.list_models(admin.id)
      assert length(models) == 2
      assert hd(models).name == "Aaa Model"
    end
  end

  describe "list_active_models/1" do
    test "filters out inactive models", %{admin: admin, provider: provider} do
      {:ok, _active} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      {:ok, _inactive} =
        LlmModels.create_model(
          valid_attrs(admin.id, provider.id)
          |> Map.merge(%{status: "inactive", model_id: "inactive-model"})
        )

      models = LlmModels.list_active_models(admin.id)
      assert length(models) == 1
      assert hd(models).status == "active"
    end

    test "filters by model_type", %{admin: admin, provider: provider} do
      {:ok, _inference} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      {:ok, _embedding} =
        LlmModels.create_model(
          valid_attrs(admin.id, provider.id)
          |> Map.merge(%{model_type: "embedding", model_id: "embed-model"})
        )

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
      {:ok, _inference} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      {:ok, _embedding} =
        LlmModels.create_model(
          valid_attrs(admin.id, provider.id)
          |> Map.merge(%{model_type: "embedding", model_id: "embed-model"})
        )

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

      {:ok, _model_on_inactive} =
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

      {:ok, _model_on_active} =
        LlmModels.create_model(%{
          name: "Model on Active",
          model_id: "claude-active",
          provider_id: active_provider.id,
          user_id: admin.id,
          status: "active"
        })

      models = LlmModels.list_active_models(admin.id)
      assert length(models) == 1
      assert hd(models).name == "Model on Active"
    end
  end

  describe "get_model/2" do
    test "owner can get model", %{admin: admin, provider: provider} do
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
      attrs = valid_attrs(admin.id, provider.id) |> Map.put(:instance_wide, true)
      {:ok, model} = LlmModels.create_model(attrs)

      assert {:ok, _} = LlmModels.get_model(model.id, other.id)
    end

    test "ACL-shared model accessible", %{admin: admin, other: other, provider: provider} do
      {:ok, model} = LlmModels.create_model(valid_attrs(admin.id, provider.id))
      {:ok, _} = Authorization.grant_access("llm_model", model.id, admin.id, other.id, "viewer")

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

      assert Keyword.get(opts, :provider_options) |> Keyword.get(:region) == "us-west-2"
      assert Keyword.get(opts, :provider_options) |> Keyword.get(:use_converse) == true
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
      assert Keyword.get(opts, :provider_options) |> Keyword.get(:region) == "us-east-1"
    end

    test "amazon_bedrock handles nil provider_config" do
      provider = %LlmProvider{
        provider_type: "amazon_bedrock",
        api_key: nil,
        provider_config: nil
      }

      model = %LlmModel{model_id: "model-id", provider: provider}

      {_model_spec, opts} = LlmModels.build_provider_options(model)
      assert Keyword.get(opts, :provider_options) |> Keyword.get(:region) == "us-east-1"
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
      {:ok, _model} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      result = Liteskill.LLM.available_models(admin.id)
      assert is_list(result)
      assert length(result) == 1
      assert %Liteskill.LlmModels.LlmModel{} = hd(result)
    end

    test "returns empty list when no DB models configured", %{other: other} do
      result = Liteskill.LLM.available_models(other.id)
      assert result == []
    end

    test "only returns inference models", %{admin: admin, provider: provider} do
      {:ok, _inference} = LlmModels.create_model(valid_attrs(admin.id, provider.id))

      {:ok, _embedding} =
        LlmModels.create_model(
          valid_attrs(admin.id, provider.id)
          |> Map.merge(%{model_type: "embedding", model_id: "embed-model"})
        )

      result = Liteskill.LLM.available_models(admin.id)
      assert length(result) == 1
      assert hd(result).model_type == "inference"
    end
  end

  # --- Encrypted fields round-trip ---

  describe "encrypted fields" do
    test "model_config is encrypted and decrypted", %{admin: admin, provider: provider} do
      config = %{"max_tokens" => 4096, "temperature" => 0.7}

      attrs = valid_attrs(admin.id, provider.id) |> Map.put(:model_config, config)
      {:ok, model} = LlmModels.create_model(attrs)

      reloaded = Repo.get!(LlmModel, model.id)
      assert reloaded.model_config == config
    end
  end
end
