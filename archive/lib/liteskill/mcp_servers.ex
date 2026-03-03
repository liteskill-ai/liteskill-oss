defmodule Liteskill.McpServers do
  @moduledoc """
  The McpServers context. Manages MCP server registrations per user.
  """

  use Boundary,
    top_level?: true,
    deps: [
      Liteskill.Authorization,
      Liteskill.Rbac,
      Liteskill.BuiltinTools,
      Liteskill.Settings,
      Liteskill.Retry
    ],
    exports: [McpServer, Client, UserToolSelection]

  import Ecto.Query

  alias Liteskill.Authorization
  alias Liteskill.McpServers.McpServer
  alias Liteskill.McpServers.UserToolSelection
  alias Liteskill.Repo

  def list_servers(user_id) do
    accessible_ids = Authorization.accessible_entity_ids("mcp_server", user_id)

    db_servers =
      McpServer
      |> where([s], s.user_id == ^user_id or s.global == true or s.id in subquery(accessible_ids))
      |> order_by([s], asc: s.name)
      |> limit(1000)
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
             |> McpServer.changeset(attrs, url_validation_opts())
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
      |> McpServer.changeset(attrs, url_validation_opts())
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

  # --- User tool selections ---

  @doc """
  Loads persisted server selections for the user, pruning any stale entries
  that reference servers the user can no longer access.
  """
  def load_selected_server_ids(user_id) do
    persisted =
      UserToolSelection
      |> where([s], s.user_id == ^user_id)
      |> select([s], s.server_id)
      |> Repo.all()
      |> MapSet.new()

    accessible =
      user_id
      |> list_servers()
      |> MapSet.new(& &1.id)

    valid = MapSet.intersection(persisted, accessible)
    stale = MapSet.difference(persisted, accessible)

    if MapSet.size(stale) != 0 do
      stale_list = MapSet.to_list(stale)

      UserToolSelection
      |> where([s], s.user_id == ^user_id and s.server_id in ^stale_list)
      |> Repo.delete_all()
    end

    valid
  end

  @doc """
  Persists a server selection for the user. Idempotent (on_conflict: :nothing).
  """
  def select_server(user_id, server_id) do
    %UserToolSelection{}
    |> UserToolSelection.changeset(%{user_id: user_id, server_id: server_id})
    |> Repo.insert(on_conflict: :nothing)
  end

  @doc """
  Removes a server selection for the user.
  """
  def deselect_server(user_id, server_id) do
    UserToolSelection
    |> where([s], s.user_id == ^user_id and s.server_id == ^server_id)
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Removes all server selections for the user.
  """
  def clear_selected_servers(user_id) do
    UserToolSelection
    |> where([s], s.user_id == ^user_id)
    |> Repo.delete_all()

    :ok
  end

  defdelegate authorize_owner(entity, user_id), to: Authorization

  defp url_validation_opts do
    [allow_private_urls: Liteskill.Settings.allow_private_mcp_urls?()]
  end
end
