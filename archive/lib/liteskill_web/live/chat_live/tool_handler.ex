defmodule LiteskillWeb.ChatLive.ToolHandler do
  @moduledoc false

  use LiteskillWeb, :html

  import Phoenix.LiveView, only: [put_flash: 3]

  alias Liteskill.Chat
  alias Liteskill.Chat.MessageBuilder
  alias Liteskill.Chat.ToolCall
  alias Liteskill.McpServers
  alias Liteskill.McpServers.Client, as: McpClient
  alias LiteskillWeb.ChatLive.Helpers, as: ChatHelpers

  def assigns do
    [
      available_tools: [],
      selected_server_ids: MapSet.new(),
      show_tool_picker: false,
      auto_confirm_tools: false,
      tools_loading: false,
      tool_call_modal: nil,
      pending_tool_calls: []
    ]
  end

  @events ~w(toggle_tool_picker toggle_server toggle_auto_confirm clear_tools
    refresh_tools approve_tool_call reject_tool_call show_tool_call close_tool_call_modal)

  def events, do: @events

  def handle_event("toggle_tool_picker", _params, socket) do
    show = !socket.assigns.show_tool_picker

    if show && socket.assigns.available_tools == [] do
      send(self(), :fetch_tools)
      {:noreply, assign(socket, show_tool_picker: true, tools_loading: true)}
    else
      {:noreply, assign(socket, show_tool_picker: show)}
    end
  end

  def handle_event("toggle_server", %{"server-id" => server_id}, socket) do
    user_id = socket.assigns.current_user.id
    selected = socket.assigns.selected_server_ids

    selected =
      if MapSet.member?(selected, server_id) do
        McpServers.deselect_server(user_id, server_id)
        MapSet.delete(selected, server_id)
      else
        McpServers.select_server(user_id, server_id)
        MapSet.put(selected, server_id)
      end

    {:noreply, assign(socket, selected_server_ids: selected)}
  end

  def handle_event("toggle_auto_confirm", _params, socket) do
    new_val = !socket.assigns.auto_confirm_tools
    user = socket.assigns.current_user
    Liteskill.Accounts.update_preferences(user, %{"auto_confirm_tools" => new_val})
    {:noreply, assign(socket, auto_confirm_tools: new_val)}
  end

  def handle_event("clear_tools", _params, socket) do
    McpServers.clear_selected_servers(socket.assigns.current_user.id)
    {:noreply, assign(socket, selected_server_ids: MapSet.new())}
  end

  def handle_event("refresh_tools", _params, socket) do
    send(self(), :fetch_tools)
    {:noreply, assign(socket, tools_loading: true, available_tools: [])}
  end

  def handle_event("approve_tool_call", %{"tool-use-id" => tool_use_id}, socket) do
    Chat.broadcast_tool_decision(socket.assigns.conversation.stream_id, tool_use_id, :approved)
    {:noreply, socket}
  end

  def handle_event("reject_tool_call", %{"tool-use-id" => tool_use_id}, socket) do
    Chat.broadcast_tool_decision(socket.assigns.conversation.stream_id, tool_use_id, :rejected)
    {:noreply, socket}
  end

  def handle_event("show_tool_call", %{"tool-use-id" => tool_use_id}, socket) do
    tc = find_tool_call(socket, tool_use_id)
    {:noreply, assign(socket, tool_call_modal: tc)}
  end

  def handle_event("close_tool_call_modal", _params, socket) do
    {:noreply, assign(socket, tool_call_modal: nil)}
  end

  # --- handle_info ---

  def handle_info(:fetch_tools, socket) do
    user_id = socket.assigns.current_user.id
    servers = McpServers.list_servers(user_id)
    active_servers = Enum.filter(servers, &(&1.status == "active"))

    {builtin_servers, mcp_servers} =
      Enum.split_with(active_servers, &Map.has_key?(&1, :builtin))

    builtin_tools =
      Enum.flat_map(builtin_servers, fn server ->
        Enum.map(server.builtin.list_tools(), fn tool ->
          %{
            id: "#{server.id}:#{tool["name"]}",
            server_id: server.id,
            server_name: server.name,
            name: tool["name"],
            description: tool["description"],
            input_schema: tool["inputSchema"],
            source: :builtin
          }
        end)
      end)

    {mcp_tools, errors} =
      Enum.reduce(mcp_servers, {[], []}, fn server, {tools_acc, errors_acc} ->
        case McpClient.list_tools(server) do
          {:ok, tool_list} ->
            mapped =
              Enum.map(tool_list, fn tool ->
                %{
                  id: "#{server.id}:#{tool["name"]}",
                  server_id: server.id,
                  server_name: server.name,
                  name: tool["name"],
                  description: tool["description"],
                  input_schema: tool["inputSchema"],
                  source: :mcp
                }
              end)

            {tools_acc ++ mapped, errors_acc}

          {:error, reason} ->
            require Logger

            Logger.warning("Failed to fetch tools from #{server.name}: #{inspect(reason)}")

            {tools_acc, errors_acc ++ ["#{server.name}: #{ChatHelpers.format_tool_error(reason)}"]}
        end
      end)

    socket = assign(socket, available_tools: builtin_tools ++ mcp_tools, tools_loading: false)

    socket =
      if errors == [] do
        socket
      else
        put_flash(socket, :error, "Tool fetch failed: " <> Enum.join(errors, "; "))
      end

    {:noreply, socket}
  end

  def handle_info(:reload_tool_calls, socket) do
    case socket.assigns.conversation do
      nil ->
        {:noreply, socket}

      conversation ->
        user_id = socket.assigns.current_user.id

        {:ok, messages} = Chat.list_messages(conversation.id, user_id)
        db_pending = load_pending_tool_calls(messages)

        # During streaming, load_pending_tool_calls returns [] because the message
        # hasn't completed with stop_reason: "tool_use" yet. Keep the in-memory
        # pending_tool_calls built from PubSub events in that case.
        pending =
          if db_pending == [] do
            if socket.assigns.streaming && socket.assigns.pending_tool_calls != [] do
              socket.assigns.pending_tool_calls
            else
              []
            end
          else
            db_pending
          end

        {:noreply, assign(socket, messages: messages, pending_tool_calls: pending)}
    end
  end

  # --- Public helpers (used by ChatLive.trigger_llm_stream) ---

  def build_tool_opts(socket) do
    selected = socket.assigns.selected_server_ids
    available = socket.assigns.available_tools

    selected_tools = Enum.filter(available, &MapSet.member?(selected, &1.server_id))

    if selected_tools == [] do
      []
    else
      bedrock_tools =
        Enum.map(selected_tools, fn tool ->
          %{
            "toolSpec" => %{
              "name" => tool.name,
              "description" => tool.description || "",
              "inputSchema" => %{"json" => tool.input_schema || %{}}
            }
          }
        end)

      user_id = socket.assigns.current_user.id

      tool_servers =
        Map.new(selected_tools, fn tool ->
          server =
            case McpServers.get_server(tool.server_id, user_id) do
              {:ok, s} -> s
              _ -> nil
            end

          {tool.name, server}
        end)

      [
        tools: bedrock_tools,
        tool_servers: tool_servers,
        auto_confirm: socket.assigns.auto_confirm_tools,
        user_id: user_id
      ]
    end
  end

  def build_tool_config(socket) do
    selected = socket.assigns.selected_server_ids
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
        "auto_confirm" => socket.assigns.auto_confirm_tools
      }
    end
  end

  def build_tool_opts_from_config(nil, _user_id), do: []

  def build_tool_opts_from_config(tool_config, user_id) do
    tools = tool_config["tools"] || []
    name_to_server = tool_config["tool_name_to_server_id"] || %{}
    auto_confirm = tool_config["auto_confirm"] || false

    if tools == [] do
      []
    else
      tool_servers =
        Map.new(name_to_server, fn {tool_name, server_id} ->
          server =
            case McpServers.get_server(server_id, user_id) do
              {:ok, s} -> s
              _ -> nil
            end

          {tool_name, server}
        end)

      [
        tools: tools,
        tool_servers: tool_servers,
        auto_confirm: auto_confirm,
        user_id: user_id
      ]
    end
  end

  def find_tool_call(socket, tool_use_id) do
    # Check pending (streaming) tool calls first
    case Enum.find(socket.assigns.pending_tool_calls, &(&1.tool_use_id == tool_use_id)) do
      nil ->
        # Search in DB-loaded messages
        socket.assigns.messages
        |> Enum.flat_map(&MessageBuilder.tool_calls_for_message/1)
        |> Enum.find(&(&1.tool_use_id == tool_use_id))

      tc ->
        tc
    end
  end

  def load_pending_tool_calls(messages) do
    case List.last(messages) do
      %{role: "assistant", stop_reason: "tool_use"} = msg ->
        msg
        |> MessageBuilder.tool_calls_for_message()
        |> Enum.filter(&(&1.status == "started"))

      _ ->
        []
    end
  end

  # Used by ToolCallStarted event handler
  def build_tool_call_from_event(data) do
    %ToolCall{
      tool_use_id: data["tool_use_id"],
      tool_name: data["tool_name"],
      input: data["input"],
      status: "started",
      message_id: data["message_id"]
    }
  end
end
