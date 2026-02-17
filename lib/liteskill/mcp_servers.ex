defmodule Liteskill.McpServers do
  use Boundary,
    top_level?: true,
    deps: [Liteskill.Authorization, Liteskill.Rbac, Liteskill.BuiltinTools],
    exports: [McpServer, Client]

  @moduledoc """
  The McpServers context. Manages MCP server registrations per user.
  """

  alias Liteskill.Authorization
  alias Liteskill.McpServers.McpServer
  alias Liteskill.Repo

  import Ecto.Query

  def list_servers(user_id) do
    accessible_ids = Authorization.accessible_entity_ids("mcp_server", user_id)

    db_servers =
      McpServer
      |> where([s], s.user_id == ^user_id or s.global == true or s.id in subquery(accessible_ids))
      |> order_by([s], asc: s.name)
      |> Repo.all()

    Liteskill.BuiltinTools.virtual_servers() ++ db_servers
  end

  def get_server("builtin:" <> _ = id, _user_id) do
    case Enum.find(Liteskill.BuiltinTools.virtual_servers(), &(&1.id == id)) do
      nil -> {:error, :not_found}
      server -> {:ok, server}
    end
  end

  def get_server(id, user_id) do
    case Repo.get(McpServer, id) do
      nil ->
        {:error, :not_found}

      %McpServer{user_id: ^user_id} = server ->
        {:ok, server}

      %McpServer{global: true} = server ->
        {:ok, server}

      %McpServer{} = server ->
        if Authorization.has_access?("mcp_server", server.id, user_id) do
          {:ok, server}
        else
          {:error, :not_found}
        end
    end
  end

  def create_server(attrs) do
    user_id = attrs[:user_id] || attrs["user_id"]

    with :ok <- Liteskill.Rbac.authorize(user_id, "mcp_servers:create") do
      Repo.transaction(fn ->
        case %McpServer{}
             |> McpServer.changeset(attrs)
             |> Repo.insert() do
          {:ok, server} ->
            {:ok, _} = Authorization.create_owner_acl("mcp_server", server.id, server.user_id)
            server

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    end
  end

  def update_server(server, user_id, attrs) do
    with {:ok, server} <- authorize_owner(server, user_id) do
      server
      |> McpServer.changeset(attrs)
      |> Repo.update()
    end
  end

  def delete_server(id, user_id) do
    case Repo.get(McpServer, id) do
      nil ->
        {:error, :not_found}

      server ->
        with {:ok, server} <- authorize_owner(server, user_id) do
          Repo.delete(server)
        end
    end
  end

  defp authorize_owner(entity, user_id), do: Authorization.authorize_owner(entity, user_id)
end
