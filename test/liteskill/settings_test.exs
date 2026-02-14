defmodule Liteskill.SettingsTest do
  use Liteskill.DataCase, async: true

  alias Liteskill.Settings
  alias Liteskill.Settings.ServerSettings

  describe "get/0" do
    test "creates singleton settings row when none exists" do
      Repo.delete_all(ServerSettings)
      settings = Settings.get()

      assert %ServerSettings{} = settings
      assert settings.registration_open == true
      assert settings.id != nil
    end

    test "is idempotent — returns same row on second call" do
      Repo.delete_all(ServerSettings)
      s1 = Settings.get()
      s2 = Settings.get()

      assert s1.id == s2.id
    end
  end

  describe "registration_open?/0" do
    test "returns true by default" do
      Repo.delete_all(ServerSettings)
      assert Settings.registration_open?() == true
    end

    test "returns false when registration is closed" do
      Repo.delete_all(ServerSettings)
      Settings.get()
      {:ok, _} = Settings.update(%{registration_open: false})

      assert Settings.registration_open?() == false
    end
  end

  describe "update/1" do
    test "updates registration_open setting" do
      Repo.delete_all(ServerSettings)
      Settings.get()

      assert {:ok, settings} = Settings.update(%{registration_open: false})
      assert settings.registration_open == false
    end
  end

  describe "toggle_registration/0" do
    test "flips registration_open from true to false" do
      Repo.delete_all(ServerSettings)
      Settings.get()

      assert {:ok, settings} = Settings.toggle_registration()
      assert settings.registration_open == false
    end

    test "flips registration_open from false to true" do
      Repo.delete_all(ServerSettings)
      Settings.get()
      Settings.update(%{registration_open: false})

      assert {:ok, settings} = Settings.toggle_registration()
      assert settings.registration_open == true
    end
  end
end
