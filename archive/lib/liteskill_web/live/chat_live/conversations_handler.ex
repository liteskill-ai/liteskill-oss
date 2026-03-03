defmodule LiteskillWeb.ChatLive.ConversationsHandler do
  @moduledoc false

  use LiteskillWeb, :html

  import Phoenix.LiveView, only: [push_navigate: 2, put_flash: 3]

  alias Liteskill.Chat
  alias LiteskillWeb.ChatLive.Helpers, as: ChatHelpers

  def assigns do
    [
      managed_conversations: [],
      conversations_page: 1,
      conversations_search: "",
      conversations_total: 0,
      conversations_selected: MapSet.new(),
      conversations_page_size: 20,
      confirm_bulk_delete: false,
      confirm_delete_id: nil
    ]
  end

  @events ~w(conversations_search conversations_page toggle_select_conversation
    toggle_select_all_conversations confirm_bulk_archive cancel_bulk_archive
    bulk_archive_conversations confirm_delete_conversation cancel_delete_conversation
    delete_conversation)

  def events, do: @events

  def handle_event("conversations_search", %{"search" => search}, socket) do
    search_term = String.trim(search)
    user_id = socket.assigns.current_user.id
    page_size = socket.assigns.conversations_page_size
    opts = if search_term == "", do: [], else: [search: search_term]

    managed = Chat.list_conversations(user_id, [limit: page_size, offset: 0] ++ opts)
    total = Chat.count_conversations(user_id, opts)

    {:noreply,
     assign(socket,
       managed_conversations: managed,
       conversations_search: search_term,
       conversations_page: 1,
       conversations_total: total,
       conversations_selected: MapSet.new()
     )}
  end

  def handle_event("conversations_page", %{"page" => page}, socket) do
    page = ChatHelpers.safe_page(page)
    user_id = socket.assigns.current_user.id
    page_size = socket.assigns.conversations_page_size
    search = socket.assigns.conversations_search
    opts = if search == "", do: [], else: [search: search]

    offset = (page - 1) * page_size
    managed = Chat.list_conversations(user_id, [limit: page_size, offset: offset] ++ opts)

    {:noreply,
     assign(socket,
       managed_conversations: managed,
       conversations_page: page,
       conversations_selected: MapSet.new()
     )}
  end

  def handle_event("toggle_select_conversation", %{"id" => id}, socket) do
    selected = socket.assigns.conversations_selected

    selected =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    {:noreply, assign(socket, conversations_selected: selected)}
  end

  def handle_event("toggle_select_all_conversations", _params, socket) do
    all_ids = MapSet.new(socket.assigns.managed_conversations, & &1.id)
    selected = socket.assigns.conversations_selected

    selected =
      if MapSet.equal?(selected, all_ids) and MapSet.size(all_ids) > 0,
        do: MapSet.new(),
        else: all_ids

    {:noreply, assign(socket, conversations_selected: selected)}
  end

  def handle_event("confirm_bulk_archive", _params, socket) do
    {:noreply, assign(socket, confirm_bulk_delete: true)}
  end

  def handle_event("cancel_bulk_archive", _params, socket) do
    {:noreply, assign(socket, confirm_bulk_delete: false)}
  end

  def handle_event("bulk_archive_conversations", _params, socket) do
    user_id = socket.assigns.current_user.id
    ids = MapSet.to_list(socket.assigns.conversations_selected)
    total = length(ids)

    {:ok, archived} = Chat.bulk_archive_conversations(ids, user_id)

    conversations = Chat.list_conversations(user_id)

    socket =
      socket
      |> assign(
        conversations: conversations,
        confirm_bulk_delete: false,
        conversations_selected: MapSet.new()
      )
      |> refresh_managed_conversations()

    socket =
      if archived < total do
        put_flash(socket, :error, "Archived #{archived} of #{total} conversations")
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("confirm_delete_conversation", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirm_delete_id: id)}
  end

  def handle_event("cancel_delete_conversation", _params, socket) do
    {:noreply, assign(socket, confirm_delete_id: nil)}
  end

  def handle_event("delete_conversation", _params, socket) do
    user_id = socket.assigns.current_user.id
    id = socket.assigns.confirm_delete_id

    case Chat.archive_conversation(id, user_id) do
      {:ok, _} ->
        conversations = Chat.list_conversations(user_id)
        socket = assign(socket, conversations: conversations, confirm_delete_id: nil)

        if socket.assigns.live_action == :conversations do
          {:noreply, refresh_managed_conversations(socket)}
        else
          {:noreply, push_navigate(socket, to: ~p"/")}
        end

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(confirm_delete_id: nil)
         |> put_flash(:error, action_error("delete conversation", reason))}
    end
  end

  def refresh_managed_conversations(socket) do
    user_id = socket.assigns.current_user.id
    page_size = socket.assigns.conversations_page_size
    search = socket.assigns.conversations_search
    opts = if search == "", do: [], else: [search: search]

    offset = (socket.assigns.conversations_page - 1) * page_size
    managed = Chat.list_conversations(user_id, [limit: page_size, offset: offset] ++ opts)
    total = Chat.count_conversations(user_id, opts)

    assign(socket,
      managed_conversations: managed,
      conversations_total: total
    )
  end
end
