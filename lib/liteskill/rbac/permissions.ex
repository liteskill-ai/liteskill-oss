defmodule Liteskill.Rbac.Permissions do
  @moduledoc """
  Single source of truth for valid RBAC permission strings.
  """

  @permissions [
    "conversations:create",
    "conversations:delete_any",
    "conversations:view_all",
    "mcp_servers:create",
    "mcp_servers:manage_global",
    "mcp_servers:view_all",
    "groups:create",
    "groups:manage_all",
    "agents:create",
    "agents:manage_all",
    "teams:create",
    "teams:manage_all",
    "runs:create",
    "runs:manage_all",
    "reports:create",
    "reports:manage_all",
    "sources:create",
    "sources:manage_all",
    "wiki_spaces:create",
    "wiki_spaces:manage_all",
    "schedules:create",
    "schedules:manage_all",
    "llm_providers:manage",
    "llm_models:manage",
    "admin:users:view",
    "admin:users:manage",
    "admin:users:invite",
    "admin:roles:manage",
    "admin:settings:manage",
    "admin:usage:view"
  ]

  @default_permissions [
    "conversations:create",
    "groups:create",
    "agents:create",
    "teams:create",
    "runs:create",
    "reports:create",
    "sources:create",
    "wiki_spaces:create",
    "schedules:create",
    "mcp_servers:create"
  ]

  @permission_set MapSet.new(@permissions)

  def all_permissions, do: @permissions

  def default_permissions, do: @default_permissions

  def valid?("*"), do: true
  def valid?(permission), do: MapSet.member?(@permission_set, permission)

  def grouped do
    Enum.group_by(@permissions, fn perm ->
      perm |> String.split(":") |> hd()
    end)
  end
end
