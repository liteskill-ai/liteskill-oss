defmodule LiteskillWeb.ErrorHelpersTest do
  use ExUnit.Case, async: true

  alias LiteskillWeb.ErrorHelpers

  describe "humanize_error/1" do
    test "changeset with errors" do
      cs =
        {%{}, %{name: :string}}
        |> Ecto.Changeset.cast(%{}, [])
        |> Ecto.Changeset.validate_required([:name])

      assert ErrorHelpers.humanize_error(cs) =~ "name: can't be blank"
    end

    test "known atoms" do
      assert ErrorHelpers.humanize_error(:forbidden) == "you don't have permission"
      assert ErrorHelpers.humanize_error(:not_found) == "not found"
      assert ErrorHelpers.humanize_error(:no_access) == "you don't have permission"
      assert ErrorHelpers.humanize_error(:cannot_grant_owner) == "cannot grant owner role"
      assert ErrorHelpers.humanize_error(:cannot_revoke_owner) == "cannot revoke owner access"
      assert ErrorHelpers.humanize_error(:cannot_modify_owner) == "cannot change owner's role"

      assert ErrorHelpers.humanize_error(:cannot_demote_root_admin) ==
               "cannot remove admin from root admin"
    end

    test "unknown atoms are humanized" do
      assert ErrorHelpers.humanize_error(:some_weird_error) == "some weird error"
    end

    test "binary reasons pass through" do
      assert ErrorHelpers.humanize_error("something broke") == "something broke"
    end

    test "other types get fallback" do
      assert ErrorHelpers.humanize_error({:unexpected, :tuple}) == "an unexpected error occurred"
      assert ErrorHelpers.humanize_error(42) == "an unexpected error occurred"
    end
  end

  describe "action_error/2" do
    test "formats with action context" do
      assert ErrorHelpers.action_error("create page", :forbidden) ==
               "Failed to create page: you don't have permission"
    end

    test "formats changeset with action" do
      cs =
        {%{}, %{title: :string}}
        |> Ecto.Changeset.cast(%{}, [])
        |> Ecto.Changeset.validate_required([:title])

      result = ErrorHelpers.action_error("save document", cs)
      assert result == "Failed to save document: title: can't be blank"
    end

    test "formats unknown atom with action" do
      assert ErrorHelpers.action_error("delete item", :already_deleted) ==
               "Failed to delete item: already deleted"
    end
  end

  describe "format_changeset/1" do
    test "single field error" do
      cs =
        {%{}, %{email: :string}}
        |> Ecto.Changeset.cast(%{}, [])
        |> Ecto.Changeset.validate_required([:email])

      assert ErrorHelpers.format_changeset(cs) == "email: can't be blank"
    end

    test "multiple field errors" do
      cs =
        {%{}, %{email: :string, name: :string}}
        |> Ecto.Changeset.cast(%{}, [])
        |> Ecto.Changeset.validate_required([:email, :name])

      result = ErrorHelpers.format_changeset(cs)
      assert result =~ "email: can't be blank"
      assert result =~ "name: can't be blank"
    end

    test "interpolates message opts" do
      cs =
        {%{}, %{name: :string}}
        |> Ecto.Changeset.cast(%{name: "ab"}, [:name])
        |> Ecto.Changeset.validate_length(:name, min: 3)

      assert ErrorHelpers.format_changeset(cs) =~ "name: should be at least 3 character(s)"
    end

    test "empty changeset returns empty string" do
      cs = Ecto.Changeset.cast({%{}, %{name: :string}}, %{name: "ok"}, [:name])
      assert ErrorHelpers.format_changeset(cs) == ""
    end
  end
end
