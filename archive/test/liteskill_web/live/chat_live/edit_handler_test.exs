defmodule LiteskillWeb.ChatLive.EditHandlerTest do
  use ExUnit.Case, async: true

  alias LiteskillWeb.ChatLive.EditHandler

  describe "assigns/0" do
    test "returns expected default assigns" do
      assigns = EditHandler.assigns()
      assert Keyword.get(assigns, :editing_message_id) == nil
      assert Keyword.get(assigns, :editing_message_content) == ""
      assert Keyword.get(assigns, :edit_selected_server_ids) == MapSet.new()
      assert Keyword.get(assigns, :edit_show_tool_picker) == false
      assert Keyword.get(assigns, :edit_auto_confirm_tools) == true
    end
  end

  describe "events/0" do
    test "returns all edit events" do
      events = EditHandler.events()
      assert "edit_message" in events
      assert "cancel_edit" in events
      assert "edit_form_changed" in events
      assert "edit_toggle_tool_picker" in events
      assert "edit_toggle_server" in events
      assert "edit_toggle_auto_confirm" in events
      assert "edit_clear_tools" in events
      assert "edit_refresh_tools" in events
    end

    test "confirm_edit is not in events (handled separately)" do
      refute "confirm_edit" in EditHandler.events()
    end
  end

  describe "handle_event edit_message" do
    test "sets editing assigns when message found" do
      msg = %{
        id: "m1",
        content: "Hello",
        tool_config: %{
          "servers" => [%{"id" => "s1"}],
          "auto_confirm" => false
        }
      }

      socket =
        build_socket(%{
          messages: [msg],
          available_tools: [%{id: "t1"}]
        })

      {:noreply, socket} =
        EditHandler.handle_event("edit_message", %{"message-id" => "m1"}, socket)

      assert socket.assigns.editing_message_id == "m1"
      assert socket.assigns.editing_message_content == "Hello"
      assert MapSet.member?(socket.assigns.edit_selected_server_ids, "s1")
      assert socket.assigns.edit_auto_confirm_tools == false
    end

    test "defaults auto_confirm to true when not in tool_config" do
      msg = %{id: "m1", content: "Hello", tool_config: nil}

      socket =
        build_socket(%{
          messages: [msg],
          available_tools: [%{id: "t1"}]
        })

      {:noreply, socket} =
        EditHandler.handle_event("edit_message", %{"message-id" => "m1"}, socket)

      assert socket.assigns.edit_auto_confirm_tools == true
    end

    test "defaults server_ids to empty when not in tool_config" do
      msg = %{id: "m1", content: "Hello", tool_config: nil}

      socket =
        build_socket(%{
          messages: [msg],
          available_tools: [%{id: "t1"}]
        })

      {:noreply, socket} =
        EditHandler.handle_event("edit_message", %{"message-id" => "m1"}, socket)

      assert socket.assigns.edit_selected_server_ids == MapSet.new()
    end
  end

  describe "handle_event cancel_edit" do
    test "clears editing assigns" do
      socket =
        build_socket(%{
          editing_message_id: "m1",
          editing_message_content: "Hello",
          edit_selected_server_ids: MapSet.new(["s1"]),
          edit_show_tool_picker: true,
          edit_auto_confirm_tools: false
        })

      {:noreply, socket} = EditHandler.handle_event("cancel_edit", %{}, socket)

      assert socket.assigns.editing_message_id == nil
      assert socket.assigns.editing_message_content == ""
      assert socket.assigns.edit_selected_server_ids == MapSet.new()
      assert socket.assigns.edit_show_tool_picker == false
      assert socket.assigns.edit_auto_confirm_tools == true
    end
  end

  describe "handle_event edit_form_changed" do
    test "updates editing content" do
      socket = build_socket(%{editing_message_content: ""})

      {:noreply, socket} =
        EditHandler.handle_event("edit_form_changed", %{"content" => "new text"}, socket)

      assert socket.assigns.editing_message_content == "new text"
    end
  end

  describe "handle_event edit_toggle_tool_picker" do
    test "opens picker" do
      socket =
        build_socket(%{
          edit_show_tool_picker: false,
          available_tools: [%{id: "t1"}]
        })

      {:noreply, socket} = EditHandler.handle_event("edit_toggle_tool_picker", %{}, socket)

      assert socket.assigns.edit_show_tool_picker == true
    end

    test "closes picker" do
      socket =
        build_socket(%{
          edit_show_tool_picker: true,
          available_tools: [%{id: "t1"}]
        })

      {:noreply, socket} = EditHandler.handle_event("edit_toggle_tool_picker", %{}, socket)

      assert socket.assigns.edit_show_tool_picker == false
    end
  end

  describe "handle_event edit_toggle_server" do
    test "adds server to selection" do
      socket = build_socket(%{edit_selected_server_ids: MapSet.new()})

      {:noreply, socket} =
        EditHandler.handle_event("edit_toggle_server", %{"server-id" => "s1"}, socket)

      assert MapSet.member?(socket.assigns.edit_selected_server_ids, "s1")
    end

    test "removes server from selection" do
      socket = build_socket(%{edit_selected_server_ids: MapSet.new(["s1"])})

      {:noreply, socket} =
        EditHandler.handle_event("edit_toggle_server", %{"server-id" => "s1"}, socket)

      refute MapSet.member?(socket.assigns.edit_selected_server_ids, "s1")
    end
  end

  describe "handle_event edit_toggle_auto_confirm" do
    test "toggles auto confirm" do
      socket = build_socket(%{edit_auto_confirm_tools: true})

      {:noreply, socket} = EditHandler.handle_event("edit_toggle_auto_confirm", %{}, socket)

      assert socket.assigns.edit_auto_confirm_tools == false
    end
  end

  describe "handle_event edit_clear_tools" do
    test "clears selected servers" do
      socket = build_socket(%{edit_selected_server_ids: MapSet.new(["s1"])})

      {:noreply, socket} = EditHandler.handle_event("edit_clear_tools", %{}, socket)

      assert socket.assigns.edit_selected_server_ids == MapSet.new()
    end
  end

  describe "handle_confirm_edit/2" do
    test "returns noreply for empty content" do
      socket = build_socket(%{})

      result = EditHandler.handle_confirm_edit(%{"content" => ""}, socket)

      assert {:noreply, _socket} = result
    end

    test "returns noreply for whitespace-only content" do
      socket = build_socket(%{})

      result = EditHandler.handle_confirm_edit(%{"content" => "   "}, socket)

      assert {:noreply, _socket} = result
    end
  end

  describe "clear_edit_assigns/1" do
    test "resets all edit assigns" do
      socket =
        build_socket(%{
          editing_message_id: "m1",
          editing_message_content: "test",
          edit_selected_server_ids: MapSet.new(["s1"]),
          edit_show_tool_picker: true,
          edit_auto_confirm_tools: false
        })

      socket = EditHandler.clear_edit_assigns(socket)

      assert socket.assigns.editing_message_id == nil
      assert socket.assigns.editing_message_content == ""
      assert socket.assigns.edit_selected_server_ids == MapSet.new()
      assert socket.assigns.edit_show_tool_picker == false
      assert socket.assigns.edit_auto_confirm_tools == true
    end
  end

  describe "build_edit_tool_config/1" do
    test "returns nil when no tools selected" do
      socket =
        build_socket(%{
          edit_selected_server_ids: MapSet.new(),
          available_tools: []
        })

      assert EditHandler.build_edit_tool_config(socket) == nil
    end

    test "returns config when tools are selected" do
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
          edit_selected_server_ids: MapSet.new(["s1"]),
          available_tools: tools,
          edit_auto_confirm_tools: false
        })

      config = EditHandler.build_edit_tool_config(socket)

      assert config["servers"] == [%{"id" => "s1", "name" => "Server 1"}]
      assert length(config["tools"]) == 1
      assert config["auto_confirm"] == false
    end
  end

  # --- Test helpers ---

  defp build_socket(extra_assigns) do
    base = %{
      __changed__: %{},
      editing_message_id: nil,
      editing_message_content: "",
      edit_selected_server_ids: MapSet.new(),
      edit_show_tool_picker: false,
      edit_auto_confirm_tools: true,
      available_tools: [],
      tools_loading: false,
      messages: [],
      flash: %{}
    }

    assigns = Map.merge(base, extra_assigns)
    %Phoenix.LiveView.Socket{assigns: assigns}
  end
end
