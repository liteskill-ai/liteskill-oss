defmodule Liteskill.McpServers.UserToolSelectionTest do
  use ExUnit.Case, async: true

  alias Liteskill.McpServers.UserToolSelection

  describe "changeset/2" do
    test "valid with user_id and server_id" do
      changeset =
        UserToolSelection.changeset(%UserToolSelection{}, %{
          user_id: Ecto.UUID.generate(),
          server_id: "builtin:reports"
        })

      assert changeset.valid?
    end

    test "invalid without server_id" do
      changeset =
        UserToolSelection.changeset(%UserToolSelection{}, %{
          user_id: Ecto.UUID.generate()
        })

      refute changeset.valid?
      assert %{server_id: _} = errors_on(changeset)
    end

    test "invalid without user_id" do
      changeset =
        UserToolSelection.changeset(%UserToolSelection{}, %{
          server_id: "builtin:reports"
        })

      refute changeset.valid?
      assert %{user_id: _} = errors_on(changeset)
    end

    test "invalid with empty attrs" do
      changeset = UserToolSelection.changeset(%UserToolSelection{}, %{})
      refute changeset.valid?
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
