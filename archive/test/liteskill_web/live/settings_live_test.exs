defmodule LiteskillWeb.SettingsLiveTest do
  use ExUnit.Case, async: true

  alias LiteskillWeb.SettingsLive

  describe "settings_action?/1" do
    test "returns true for all settings actions" do
      for action <- [
            :settings_usage,
            :settings_general,
            :settings_providers,
            :settings_models,
            :settings_rag,
            :settings_account
          ] do
        assert SettingsLive.settings_action?(action), "expected #{action} to be a settings action"
      end
    end

    test "returns false for non-settings actions" do
      refute SettingsLive.settings_action?(:admin_usage)
      refute SettingsLive.settings_action?(:info)
      refute SettingsLive.settings_action?(:show)
    end
  end

  describe "settings_to_admin_action/1" do
    test "maps settings actions to admin actions" do
      assert SettingsLive.settings_to_admin_action(:settings_usage) == :admin_usage
      assert SettingsLive.settings_to_admin_action(:settings_general) == :admin_servers
      assert SettingsLive.settings_to_admin_action(:settings_providers) == :admin_providers
      assert SettingsLive.settings_to_admin_action(:settings_models) == :admin_models
      assert SettingsLive.settings_to_admin_action(:settings_rag) == :admin_rag
    end

    test "returns nil for non-admin settings actions" do
      assert SettingsLive.settings_to_admin_action(:settings_account) == nil
    end

    test "returns nil for unknown actions" do
      assert SettingsLive.settings_to_admin_action(:unknown) == nil
    end
  end
end
