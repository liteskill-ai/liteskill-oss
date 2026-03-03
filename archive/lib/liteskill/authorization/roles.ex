defmodule Liteskill.Authorization.Roles do
  @moduledoc """
  Single source of truth for the role hierarchy.

  Role rank (lowest to highest): viewer < editor < manager < owner
  """

  @role_rank %{"viewer" => 0, "editor" => 1, "manager" => 2, "owner" => 3}

  @doc "All valid role strings."
  def valid_roles, do: Map.keys(@role_rank)

  @doc "Returns the highest-ranked role from a list."
  def highest(roles) when is_list(roles) do
    Enum.max_by(roles, &rank/1)
  end

  @doc "Numeric rank of a role. Returns -1 for unknown roles."
  def rank(role), do: Map.get(@role_rank, role, -1)

  @doc "True if `role` is at or above `minimum`."
  def at_least?(role, minimum), do: rank(role) >= rank(minimum)
end
