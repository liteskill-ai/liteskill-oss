defmodule LiteskillWeb.SharingLive do
  @moduledoc """
  Sharing event handlers, delegated from ChatLive and WikiLive.
  """

  use LiteskillWeb, :html

  @sharing_events ~w(open_sharing close_sharing search_users grant_access
    grant_group_access change_role revoke_access revoke_group_access)

  def sharing_events, do: @sharing_events

  def sharing_assigns do
    [
      show_sharing: false,
      sharing_entity_type: nil,
      sharing_entity_id: nil,
      sharing_acls: [],
      sharing_user_search_results: [],
      sharing_user_search_query: "",
      sharing_groups: [],
      sharing_error: nil
    ]
  end

  def handle_event("open_sharing", %{"entity-type" => type, "entity-id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    # Bootstrap owner ACL if none exist AND user actually owns the entity
    if Liteskill.Authorization.list_acls(type, id) == [] do
      schema = ownership_schema(type)

      if schema && Liteskill.Authorization.verify_ownership(schema, id, user_id) == :ok do
        Liteskill.Authorization.create_owner_acl(type, id, user_id)
      end
    end

    # Authorize: user must have access to view sharing settings
    if Liteskill.Authorization.has_access?(type, id, user_id) do
      acls = Liteskill.Authorization.list_acls(type, id)
      groups = Liteskill.Groups.list_groups(user_id)

      filtered_groups =
        Enum.reject(groups, fn g ->
          Enum.any?(acls, &(&1.group_id == g.id))
        end)

      {:noreply,
       Phoenix.Component.assign(socket,
         show_sharing: true,
         sharing_entity_type: type,
         sharing_entity_id: id,
         sharing_acls: acls,
         sharing_user_search_results: [],
         sharing_user_search_query: "",
         sharing_groups: filtered_groups,
         sharing_error: nil
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_sharing", _params, socket) do
    {:noreply,
     Phoenix.Component.assign(socket,
       show_sharing: false,
       sharing_entity_type: nil,
       sharing_entity_id: nil,
       sharing_acls: [],
       sharing_user_search_results: [],
       sharing_user_search_query: "",
       sharing_groups: [],
       sharing_error: nil
     )}
  end

  def handle_event("search_users", %{"user_search" => query}, socket) do
    if String.length(query) >= 2 do
      existing_user_ids =
        Enum.map(socket.assigns.sharing_acls, & &1.user_id) |> Enum.reject(&is_nil/1)

      exclude = [socket.assigns.current_user.id | existing_user_ids]
      results = Liteskill.Accounts.search_users(query, exclude: exclude, limit: 5)

      {:noreply,
       Phoenix.Component.assign(socket,
         sharing_user_search_results: results,
         sharing_user_search_query: query
       )}
    else
      {:noreply,
       Phoenix.Component.assign(socket,
         sharing_user_search_results: [],
         sharing_user_search_query: query
       )}
    end
  end

  def handle_event("grant_access", %{"user-id" => user_id, "role" => role}, socket) do
    type = socket.assigns.sharing_entity_type
    id = socket.assigns.sharing_entity_id
    grantor_id = socket.assigns.current_user.id

    case Liteskill.Authorization.grant_access(type, id, grantor_id, user_id, role) do
      {:ok, _acl} ->
        acls = Liteskill.Authorization.list_acls(type, id)

        {:noreply,
         Phoenix.Component.assign(socket,
           sharing_acls: acls,
           sharing_user_search_results: [],
           sharing_user_search_query: "",
           sharing_error: nil
         )}

      {:error, reason} ->
        {:noreply, Phoenix.Component.assign(socket, sharing_error: humanize_error(reason))}
    end
  end

  def handle_event("grant_group_access", %{"group-id" => group_id, "role" => role}, socket) do
    type = socket.assigns.sharing_entity_type
    id = socket.assigns.sharing_entity_id
    grantor_id = socket.assigns.current_user.id

    case Liteskill.Authorization.grant_group_access(type, id, grantor_id, group_id, role) do
      {:ok, _acl} ->
        acls = Liteskill.Authorization.list_acls(type, id)
        groups = Liteskill.Groups.list_groups(grantor_id)

        filtered_groups =
          Enum.reject(groups, fn g -> Enum.any?(acls, &(&1.group_id == g.id)) end)

        {:noreply,
         Phoenix.Component.assign(socket,
           sharing_acls: acls,
           sharing_groups: filtered_groups,
           sharing_error: nil
         )}

      {:error, reason} ->
        {:noreply, Phoenix.Component.assign(socket, sharing_error: humanize_error(reason))}
    end
  end

  def handle_event("change_role", %{"acl-id" => acl_id, "role" => new_role}, socket) do
    type = socket.assigns.sharing_entity_type
    id = socket.assigns.sharing_entity_id
    grantor_id = socket.assigns.current_user.id

    acl = Enum.find(socket.assigns.sharing_acls, &(&1.id == acl_id))

    if acl && acl.user_id do
      case Liteskill.Authorization.update_role(type, id, grantor_id, acl.user_id, new_role) do
        {:ok, _} ->
          acls = Liteskill.Authorization.list_acls(type, id)
          {:noreply, Phoenix.Component.assign(socket, sharing_acls: acls, sharing_error: nil)}

        {:error, reason} ->
          {:noreply, Phoenix.Component.assign(socket, sharing_error: humanize_error(reason))}
      end
    else
      {:noreply, Phoenix.Component.assign(socket, sharing_error: "Role change not applicable")}
    end
  end

  def handle_event("revoke_access", %{"user-id" => user_id}, socket) do
    type = socket.assigns.sharing_entity_type
    id = socket.assigns.sharing_entity_id
    revoker_id = socket.assigns.current_user.id

    case Liteskill.Authorization.revoke_access(type, id, revoker_id, user_id) do
      {:ok, _} ->
        acls = Liteskill.Authorization.list_acls(type, id)
        {:noreply, Phoenix.Component.assign(socket, sharing_acls: acls, sharing_error: nil)}

      {:error, reason} ->
        {:noreply, Phoenix.Component.assign(socket, sharing_error: humanize_error(reason))}
    end
  end

  def handle_event("revoke_group_access", %{"group-id" => group_id}, socket) do
    type = socket.assigns.sharing_entity_type
    id = socket.assigns.sharing_entity_id
    revoker_id = socket.assigns.current_user.id

    case Liteskill.Authorization.revoke_group_access(type, id, revoker_id, group_id) do
      {:ok, _} ->
        acls = Liteskill.Authorization.list_acls(type, id)
        groups = Liteskill.Groups.list_groups(revoker_id)

        filtered_groups =
          Enum.reject(groups, fn g -> Enum.any?(acls, &(&1.group_id == g.id)) end)

        {:noreply,
         Phoenix.Component.assign(socket,
           sharing_acls: acls,
           sharing_groups: filtered_groups,
           sharing_error: nil
         )}

      {:error, reason} ->
        {:noreply, Phoenix.Component.assign(socket, sharing_error: humanize_error(reason))}
    end
  end

  defp ownership_schema("agent_definition"), do: Liteskill.Agents.AgentDefinition
  defp ownership_schema("conversation"), do: Liteskill.Chat.Conversation
  defp ownership_schema("data_source"), do: Liteskill.DataSources.Source
  defp ownership_schema("run"), do: Liteskill.Runs.Run
  defp ownership_schema("llm_model"), do: Liteskill.LlmModels.LlmModel
  defp ownership_schema("llm_provider"), do: Liteskill.LlmProviders.LlmProvider
  defp ownership_schema("mcp_server"), do: Liteskill.McpServers.McpServer
  defp ownership_schema("schedule"), do: Liteskill.Schedules.Schedule
  defp ownership_schema("team_definition"), do: Liteskill.Teams.TeamDefinition
  defp ownership_schema("wiki_space"), do: Liteskill.DataSources.Document
  defp ownership_schema(_), do: nil
end
