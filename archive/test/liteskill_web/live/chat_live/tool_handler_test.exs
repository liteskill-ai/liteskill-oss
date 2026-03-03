defmodule LiteskillWeb.ChatLive.ToolHandlerTest do
  use ExUnit.Case, async: true

  alias Liteskill.Chat.ToolCall
  alias LiteskillWeb.ChatLive.ToolHandler

  describe "assigns/0" do
    test "returns expected default assigns" do
      assigns = ToolHandler.assigns()
      assert Keyword.get(assigns, :available_tools) == []
      assert Keyword.get(assigns, :selected_server_ids) == MapSet.new()
      assert Keyword.get(assigns, :show_tool_picker) == false
      assert Keyword.get(assigns, :auto_confirm_tools) == false
      assert Keyword.get(assigns, :tools_loading) == false
      assert Keyword.get(assigns, :tool_call_modal) == nil
      assert Keyword.get(assigns, :pending_tool_calls) == []
    end
  end

  describe "events/0" do
    test "returns all tool events" do
      events = ToolHandler.events()
      assert "toggle_tool_picker" in events
      assert "toggle_server" in events
      assert "toggle_auto_confirm" in events
      assert "clear_tools" in events
      assert "refresh_tools" in events
      assert "approve_tool_call" in events
      assert "reject_tool_call" in events
      assert "show_tool_call" in events
      assert "close_tool_call_modal" in events
    end
  end

  describe "handle_event toggle_tool_picker" do
    test "opens picker" do
      socket = build_socket(%{show_tool_picker: false, available_tools: [%{id: "t1"}]})

      {:noreply, socket} = ToolHandler.handle_event("toggle_tool_picker", %{}, socket)

      assert socket.assigns.show_tool_picker == true
    end

    test "closes picker" do
      socket = build_socket(%{show_tool_picker: true, available_tools: [%{id: "t1"}]})

      {:noreply, socket} = ToolHandler.handle_event("toggle_tool_picker", %{}, socket)

      assert socket.assigns.show_tool_picker == false
    end
  end

  describe "handle_event close_tool_call_modal" do
    test "clears tool_call_modal" do
      socket = build_socket(%{tool_call_modal: %ToolCall{}})

      {:noreply, socket} = ToolHandler.handle_event("close_tool_call_modal", %{}, socket)

      assert socket.assigns.tool_call_modal == nil
    end
  end

  describe "build_tool_config/1" do
    test "returns nil when no tools selected" do
      socket = build_socket(%{selected_server_ids: MapSet.new(), available_tools: []})
      assert ToolHandler.build_tool_config(socket) == nil
    end

    test "returns config map when tools are selected" do
      tools = [
        %{
          id: "s1:tool1",
          server_id: "s1",
          server_name: "Server 1",
          name: "tool1",
          description: "desc",
          input_schema: %{"type" => "object"}
        }
      ]

      socket =
        build_socket(%{
          selected_server_ids: MapSet.new(["s1"]),
          available_tools: tools,
          auto_confirm_tools: true
        })

      config = ToolHandler.build_tool_config(socket)

      assert config["servers"] == [%{"id" => "s1", "name" => "Server 1"}]
      assert length(config["tools"]) == 1
      assert config["tool_name_to_server_id"] == %{"tool1" => "s1"}
      assert config["auto_confirm"] == true
    end
  end

  describe "build_tool_opts_from_config/2" do
    test "returns empty list for nil config" do
      assert ToolHandler.build_tool_opts_from_config(nil, "user-1") == []
    end

    test "returns empty list for config with no tools" do
      config = %{"tools" => [], "tool_name_to_server_id" => %{}}
      assert ToolHandler.build_tool_opts_from_config(config, "user-1") == []
    end
  end

  describe "find_tool_call/2" do
    test "finds in pending tool calls first" do
      tc = %ToolCall{tool_use_id: "tu-1", tool_name: "test", status: "started"}
      socket = build_socket(%{pending_tool_calls: [tc], messages: []})

      assert ToolHandler.find_tool_call(socket, "tu-1") == tc
    end

    test "returns nil when not found" do
      socket = build_socket(%{pending_tool_calls: [], messages: []})

      assert ToolHandler.find_tool_call(socket, "tu-1") == nil
    end
  end

  describe "load_pending_tool_calls/1" do
    test "returns empty for no messages" do
      assert ToolHandler.load_pending_tool_calls([]) == []
    end

    test "returns empty when last message is not assistant tool_use" do
      messages = [%{role: "user", stop_reason: nil}]
      assert ToolHandler.load_pending_tool_calls(messages) == []
    end
  end

  describe "build_tool_call_from_event/1" do
    test "builds ToolCall struct from event data" do
      data = %{
        "tool_use_id" => "tu-1",
        "tool_name" => "search",
        "input" => %{"query" => "test"},
        "message_id" => "m-1"
      }

      tc = ToolHandler.build_tool_call_from_event(data)

      assert %ToolCall{} = tc
      assert tc.tool_use_id == "tu-1"
      assert tc.tool_name == "search"
      assert tc.input == %{"query" => "test"}
      assert tc.status == "started"
      assert tc.message_id == "m-1"
    end
  end

  # --- Test helpers ---

  defp build_socket(extra_assigns) do
    base = %{
      __changed__: %{},
      available_tools: [],
      selected_server_ids: MapSet.new(),
      show_tool_picker: false,
      auto_confirm_tools: false,
      tools_loading: false,
      tool_call_modal: nil,
      pending_tool_calls: [],
      messages: [],
      flash: %{}
    }

    assigns = Map.merge(base, extra_assigns)
    %Phoenix.LiveView.Socket{assigns: assigns}
  end
end
