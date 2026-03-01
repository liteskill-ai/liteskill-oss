defmodule Liteskill.DataSources.ConnectorRegistryTest do
  use ExUnit.Case, async: true

  alias Liteskill.DataSources.ConnectorRegistry
  alias Liteskill.DataSources.Connectors.GoogleDrive
  alias Liteskill.DataSources.Connectors.Wiki

  describe "get/1" do
    test "returns wiki connector for 'wiki' type" do
      assert {:ok, Wiki} = ConnectorRegistry.get("wiki")
    end

    test "returns google_drive connector for 'google_drive' type" do
      assert {:ok, GoogleDrive} =
               ConnectorRegistry.get("google_drive")
    end

    test "returns error for unknown type" do
      assert {:error, :unknown_connector} = ConnectorRegistry.get("nonexistent")
    end

    test "returns error for empty string" do
      assert {:error, :unknown_connector} = ConnectorRegistry.get("")
    end
  end

  describe "all/0" do
    test "returns all registered connectors" do
      all = ConnectorRegistry.all()
      assert is_list(all)
      assert {"wiki", Wiki} in all
      assert {"google_drive", GoogleDrive} in all
    end
  end
end
