defmodule Liteskill.Rbac.PermissionsTest do
  use ExUnit.Case, async: true

  alias Liteskill.Rbac.Permissions

  describe "all_permissions/0" do
    test "returns non-empty list" do
      perms = Permissions.all_permissions()
      assert [_ | _] = perms
    end

    test "all entries are strings" do
      assert Enum.all?(Permissions.all_permissions(), &is_binary/1)
    end
  end

  describe "default_permissions/0" do
    test "returns a subset of all_permissions" do
      all = MapSet.new(Permissions.all_permissions())
      default = MapSet.new(Permissions.default_permissions())
      assert MapSet.subset?(default, all)
    end

    test "includes create permissions" do
      defaults = Permissions.default_permissions()
      assert "conversations:create" in defaults
      assert "agents:create" in defaults
    end
  end

  describe "valid?/1" do
    test "returns true for known permissions" do
      assert Permissions.valid?("conversations:create")
      assert Permissions.valid?("admin:roles:manage")
    end

    test "returns true for wildcard" do
      assert Permissions.valid?("*")
    end

    test "returns false for unknown permissions" do
      refute Permissions.valid?("nonexistent:permission")
      refute Permissions.valid?("")
    end
  end

  describe "grouped/0" do
    test "returns a map grouped by category" do
      grouped = Permissions.grouped()
      assert is_map(grouped)
      assert Map.has_key?(grouped, "conversations")
      assert Map.has_key?(grouped, "admin")
      assert "conversations:create" in grouped["conversations"]
    end
  end
end
