defmodule Liteskill.Rbac.RoleTest do
  use ExUnit.Case, async: true

  alias Liteskill.Rbac.Role

  describe "changeset/2" do
    test "valid with name and permissions" do
      changeset =
        Role.changeset(%Role{}, %{name: "Test Role", permissions: ["conversations:create"]})

      assert changeset.valid?
    end

    test "requires name" do
      changeset = Role.changeset(%Role{}, %{})
      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects invalid permissions" do
      changeset = Role.changeset(%Role{}, %{name: "Bad", permissions: ["fake:perm"]})
      refute changeset.valid?
      assert %{permissions: [msg]} = errors_on(changeset)
      assert msg =~ "invalid permissions"
    end

    test "accepts empty permissions" do
      changeset = Role.changeset(%Role{}, %{name: "Empty", permissions: []})
      assert changeset.valid?
    end
  end

  describe "system_changeset/2" do
    test "allows setting system flag" do
      changeset =
        Role.system_changeset(%Role{}, %{name: "System", system: true, permissions: ["*"]})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :system) == true
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
