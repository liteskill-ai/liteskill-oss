defmodule LiteskillWeb.ChatLive.EditHandler do
  @moduledoc false

  use LiteskillWeb, :html

  import Phoenix.LiveView, only: [put_flash: 3]

  alias Liteskill.Chat

  def assigns do
    [
      editing_message_id: nil,
      editing_message_content: "",
      edit_selected_server_ids: MapSet.new(),
      edit_show_tool_picker: false,
      edit_auto_confirm_tools: true
    ]
  end

  @events ~w(edit_message cancel_edit edit_form_changed
    edit_toggle_tool_picker edit_toggle_server edit_toggle_auto_confirm
    edit_clear_tools edit_refresh_tools)

  def events, do: @events

  # Note: "confirm_edit" is handled specially in ChatLive (needs trigger_llm_stream)

  def handle_event("edit_message", %{"message-id" => message_id}, socket) do
    message = Enum.find(socket.assigns.messages, &(&1.id == message_id))

    if message do
      server_ids =
        case message.tool_config do
          %{"servers" => servers} when is_list(servers) ->
            MapSet.new(servers, & &1["id"])

          _ ->
            MapSet.new()
        end

      auto_confirm =
        case message.tool_config do
          %{"auto_confirm" => val} -> val
          _ -> true
        end

      if socket.assigns.available_tools == [] do
        send(self(), :fetch_tools)
      end

      {:noreply,
       assign(socket,
         editing_message_id: message_id,
         editing_message_content: message.content,
         edit_selected_server_ids: server_ids,
         edit_show_tool_picker: false,
         edit_auto_confirm_tools: auto_confirm
       )}
    else
      {:noreply, put_flash(socket, :error, "Message not found")}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, clear_edit_assigns(socket)}
  end

  def handle_event("edit_form_changed", %{"content" => content}, socket) do
    {:noreply, assign(socket, editing_message_content: content)}
  end

  def handle_event("edit_toggle_tool_picker", _params, socket) do
    show = !socket.assigns.edit_show_tool_picker

    if show && socket.assigns.available_tools == [] do
      send(self(), :fetch_tools)
      {:noreply, assign(socket, edit_show_tool_picker: true, tools_loading: true)}
    else
      {:noreply, assign(socket, edit_show_tool_picker: show)}
    end
  end

  def handle_event("edit_toggle_server", %{"server-id" => server_id}, socket) do
    selected = socket.assigns.edit_selected_server_ids

    selected =
      if MapSet.member?(selected, server_id) do
        MapSet.delete(selected, server_id)
      else
        MapSet.put(selected, server_id)
      end

    {:noreply, assign(socket, edit_selected_server_ids: selected)}
  end

  def handle_event("edit_toggle_auto_confirm", _params, socket) do
    {:noreply, assign(socket, edit_auto_confirm_tools: !socket.assigns.edit_auto_confirm_tools)}
  end

  def handle_event("edit_clear_tools", _params, socket) do
    {:noreply, assign(socket, edit_selected_server_ids: MapSet.new())}
  end

  def handle_event("edit_refresh_tools", _params, socket) do
    send(self(), :fetch_tools)
    {:noreply, assign(socket, tools_loading: true, available_tools: [])}
  end

  @doc """
  Handles confirm_edit — returns either:
    - `{:stream, socket, conversation, tool_config}` when ChatLive should trigger a stream
    - `{:noreply, socket}` for empty content or errors
  """
  def handle_confirm_edit(%{"content" => content}, socket) do
    content = String.trim(content)

    if content == "" do
      {:noreply, socket}
    else
      conversation = socket.assigns.conversation
      user_id = socket.assigns.current_user.id
      message_id = socket.assigns.editing_message_id
      tool_config = build_edit_tool_config(socket)

      case Chat.edit_message(conversation.id, user_id, message_id, content, tool_config: tool_config) do
        {:ok, _message} ->
          {:ok, updated_conv} = Chat.get_conversation(conversation.id, user_id)

          socket =
            socket
            |> clear_edit_assigns()
            |> assign(
              conversation: updated_conv,
              messages: updated_conv.messages
            )

          {:stream, socket, updated_conv, tool_config}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, action_error("edit message", reason))}
      end
    end
  end

  def clear_edit_assigns(socket) do
    assign(socket,
      editing_message_id: nil,
      editing_message_content: "",
      edit_selected_server_ids: MapSet.new(),
      edit_show_tool_picker: false,
      edit_auto_confirm_tools: true
    )
  end

  def build_edit_tool_config(socket) do
    selected = socket.assigns.edit_selected_server_ids
    available = socket.assigns.available_tools

    selected_tools = Enum.filter(available, &MapSet.member?(selected, &1.server_id))

    if selected_tools == [] do
      nil
    else
      servers =
        selected_tools
        |> Enum.map(& &1.server_id)
        |> Enum.uniq()
        |> Enum.map(fn sid ->
          tool = Enum.find(selected_tools, &(&1.server_id == sid))
          %{"id" => sid, "name" => tool.server_name}
        end)

      tools =
        Enum.map(selected_tools, fn tool ->
          %{
            "toolSpec" => %{
              "name" => tool.name,
              "description" => tool.description || "",
              "inputSchema" => %{"json" => tool.input_schema || %{}}
            }
          }
        end)

      tool_name_to_server_id = Map.new(selected_tools, &{&1.name, &1.server_id})

      %{
        "servers" => servers,
        "tools" => tools,
        "tool_name_to_server_id" => tool_name_to_server_id,
        "auto_confirm" => socket.assigns.edit_auto_confirm_tools
      }
    end
  end
end
