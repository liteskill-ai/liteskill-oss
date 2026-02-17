defmodule LiteskillWeb.GroupController do
  use LiteskillWeb, :controller

  alias Liteskill.Groups

  action_fallback LiteskillWeb.FallbackController

  def index(conn, _params) do
    user = conn.assigns.current_user
    groups = Groups.list_groups(user.id)
    json(conn, %{data: Enum.map(groups, &group_json/1)})
  end

  def create(conn, %{"name" => name}) do
    user = conn.assigns.current_user

    with :ok <- Liteskill.Rbac.authorize(user.id, "groups:create"),
         {:ok, group} <- Groups.create_group(name, user.id) do
      conn
      |> put_status(:created)
      |> json(%{data: group_json(group)})
    end
  end

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, group} <- Groups.get_group(id, user.id) do
      json(conn, %{data: group_json(group)})
    end
  end

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, _group} <- Groups.delete_group(id, user.id) do
      send_resp(conn, :no_content, "")
    end
  end

  def add_member(conn, %{"group_id" => group_id, "user_id" => target_user_id} = params) do
    user = conn.assigns.current_user
    role = Map.get(params, "role", "member")

    case Groups.add_member(group_id, user.id, target_user_id, role) do
      {:ok, membership} ->
        conn
        |> put_status(:created)
        |> json(%{
          data: %{
            id: membership.id,
            group_id: membership.group_id,
            user_id: membership.user_id,
            role: membership.role
          }
        })

      {:error, reason} ->
        {:error, reason}
    end
  end

  def remove_member(conn, %{"group_id" => group_id, "user_id" => target_user_id}) do
    user = conn.assigns.current_user

    case Groups.remove_member(group_id, user.id, target_user_id) do
      {:ok, _} ->
        send_resp(conn, :no_content, "")

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp group_json(group) do
    %{
      id: group.id,
      name: group.name,
      created_by: group.created_by,
      inserted_at: group.inserted_at,
      updated_at: group.updated_at
    }
  end
end
