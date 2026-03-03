defmodule Liteskill.Authorization.RolesTest do
  use ExUnit.Case, async: true

  alias Liteskill.Authorization.Roles

  test "valid_roles returns all roles" do
    roles = Roles.valid_roles()
    assert "viewer" in roles
    assert "editor" in roles
    assert "manager" in roles
    assert "owner" in roles
    assert length(roles) == 4
  end

  test "rank orders correctly" do
    assert Roles.rank("viewer") < Roles.rank("editor")
    assert Roles.rank("editor") < Roles.rank("manager")
    assert Roles.rank("manager") < Roles.rank("owner")
  end

  test "rank returns -1 for unknown role" do
    assert Roles.rank("bogus") == -1
  end

  test "highest returns the highest-ranked role" do
    assert Roles.highest(["viewer", "manager"]) == "manager"
    assert Roles.highest(["owner", "viewer"]) == "owner"
    assert Roles.highest(["editor"]) == "editor"
  end

  test "at_least? checks minimum role" do
    assert Roles.at_least?("owner", "viewer")
    assert Roles.at_least?("manager", "manager")
    refute Roles.at_least?("viewer", "editor")
    refute Roles.at_least?("editor", "manager")
  end
end
