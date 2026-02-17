defmodule LiteskillWeb.ErrorHelpers do
  @moduledoc """
  Centralised helpers for turning `{:error, reason}` tuples into
  human-readable strings.  Imported automatically in all LiveViews
  and controllers via `LiteskillWeb`.
  """

  @doc """
  Turns any error reason into a human-readable string.

      iex> humanize_error(:forbidden)
      "you don't have permission"

      iex> humanize_error(:not_found)
      "not found"
  """
  def humanize_error(%Ecto.Changeset{} = cs), do: format_changeset(cs)
  def humanize_error(:forbidden), do: "you don't have permission"
  def humanize_error(:not_found), do: "not found"
  def humanize_error(:no_access), do: "you don't have permission"
  def humanize_error(:cannot_grant_owner), do: "cannot grant owner role"
  def humanize_error(:cannot_revoke_owner), do: "cannot revoke owner access"
  def humanize_error(:cannot_modify_owner), do: "cannot change owner's role"
  def humanize_error(:cannot_demote_root_admin), do: "cannot remove admin from root admin"

  def humanize_error(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.replace("_", " ")

  def humanize_error(reason) when is_binary(reason), do: reason

  def humanize_error(_), do: "an unexpected error occurred"

  @doc """
  Formats an error with action context.

      iex> action_error("create page", :forbidden)
      "Failed to create page: you don't have permission"
  """
  def action_error(action, reason) do
    "Failed to #{action}: #{humanize_error(reason)}"
  end

  @doc """
  Formats an `Ecto.Changeset` into a flat, human-readable error string.

  Interpolates any `%{key}` placeholders in validation messages.
  """
  def format_changeset(%Ecto.Changeset{} = cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join(", ", fn {field, msgs} ->
      "#{field}: #{Enum.join(msgs, ", ")}"
    end)
  end
end
