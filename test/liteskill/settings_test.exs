defmodule Liteskill.SettingsTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Settings
  alias Liteskill.Settings.ServerSettings

  setup do
    Repo.delete_all(ServerSettings)
    :ok
  end

  describe "get/0" do
    test "creates singleton settings row when none exists" do
      settings = Settings.get()

      assert %ServerSettings{} = settings
      assert settings.registration_open == true
      assert settings.id != nil
    end

    test "is idempotent — returns same row on second call" do
      s1 = Settings.get()
      s2 = Settings.get()

      assert s1.id == s2.id
    end

    test "preloads embedding_model association" do
      settings = Settings.get()
      assert %Ecto.Association.NotLoaded{} != settings.embedding_model
      assert settings.embedding_model == nil
    end
  end

  describe "registration_open?/0" do
    test "returns true by default" do
      assert Settings.registration_open?() == true
    end

    test "returns false when registration is closed" do
      Settings.get()
      {:ok, _} = Settings.update(%{registration_open: false})

      assert Settings.registration_open?() == false
    end
  end

  describe "embedding_enabled?/0" do
    test "returns false when no embedding model set" do
      assert Settings.embedding_enabled?() == false
    end

    test "returns true when embedding model is set" do
      model = create_embedding_model()
      Settings.get()
      {:ok, _} = Settings.update_embedding_model(model.id)

      assert Settings.embedding_enabled?() == true
    end
  end

  describe "update_embedding_model/1" do
    test "sets embedding_model_id" do
      model = create_embedding_model()
      Settings.get()

      assert {:ok, settings} = Settings.update_embedding_model(model.id)
      assert settings.embedding_model_id == model.id
      assert settings.embedding_model.id == model.id
    end

    test "clears embedding_model_id when nil" do
      model = create_embedding_model()
      Settings.get()
      {:ok, _} = Settings.update_embedding_model(model.id)

      assert {:ok, settings} = Settings.update_embedding_model(nil)
      assert settings.embedding_model_id == nil
      assert settings.embedding_model == nil
    end

    test "reflects update on subsequent get" do
      model = create_embedding_model()
      Settings.get()
      {:ok, _} = Settings.update_embedding_model(model.id)

      assert Settings.get().embedding_model_id == model.id
    end
  end

  describe "update/1" do
    test "updates registration_open setting" do
      Settings.get()

      assert {:ok, settings} = Settings.update(%{registration_open: false})
      assert settings.registration_open == false
    end

    test "reflects update on subsequent get" do
      Settings.get()
      {:ok, _} = Settings.update(%{registration_open: false})

      assert Settings.get().registration_open == false
    end
  end

  describe "toggle_registration/0" do
    test "flips registration_open from true to false" do
      Settings.get()

      assert {:ok, settings} = Settings.toggle_registration()
      assert settings.registration_open == false
    end

    test "flips registration_open from false to true" do
      Settings.get()
      Settings.update(%{registration_open: false})

      assert {:ok, settings} = Settings.toggle_registration()
      assert settings.registration_open == true
    end
  end

  describe "allow_private_mcp_urls?/0" do
    test "returns false by default" do
      assert Settings.allow_private_mcp_urls?() == false
    end

    test "returns true when enabled" do
      Settings.get()
      {:ok, _} = Settings.update(%{allow_private_mcp_urls: true})

      assert Settings.allow_private_mcp_urls?() == true
    end
  end

  describe "bust_cache/0" do
    test "erases persistent_term entry" do
      # In test mode, cache is disabled, but bust_cache should not crash
      Settings.bust_cache()
      assert %ServerSettings{} = Settings.get()
    end
  end

  defp create_embedding_model do
    {:ok, user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "settings-test-#{System.unique_integer([:positive])}@example.com",
        name: "Test",
        oidc_sub: "settings-test-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, provider} =
      Liteskill.LlmProviders.create_provider(%{
        name: "Test Bedrock",
        provider_type: "amazon_bedrock",
        api_key: "test-key",
        provider_config: %{"region" => "us-east-1"},
        user_id: user.id
      })

    {:ok, model} =
      Liteskill.LlmModels.create_model(%{
        name: "Cohere Embed v4",
        model_id: "us.cohere.embed-v4:0",
        model_type: "embedding",
        instance_wide: true,
        provider_id: provider.id,
        user_id: user.id
      })

    model
  end
end
