defmodule LiteskillWeb.ChatLive.ConversationsHandlerTest do
  use ExUnit.Case, async: true

  alias LiteskillWeb.ChatLive.ConversationsHandler

  describe "assigns/0" do
    test "returns expected default assigns" do
      assigns = ConversationsHandler.assigns()
      assert Keyword.get(assigns, :managed_conversations) == []
      assert Keyword.get(assigns, :conversations_page) == 1
      assert Keyword.get(assigns, :conversations_search) == ""
      assert Keyword.get(assigns, :conversations_total) == 0
      assert Keyword.get(assigns, :conversations_selected) == MapSet.new()
      assert Keyword.get(assigns, :conversations_page_size) == 20
      assert Keyword.get(assigns, :confirm_bulk_delete) == false
      assert Keyword.get(assigns, :confirm_delete_id) == nil
    end
  end

  describe "events/0" do
    test "returns all conversation management events" do
      events = ConversationsHandler.events()
      assert "conversations_search" in events
      assert "conversations_page" in events
      assert "toggle_select_conversation" in events
      assert "toggle_select_all_conversations" in events
      assert "confirm_bulk_archive" in events
      assert "cancel_bulk_archive" in events
      assert "bulk_archive_conversations" in events
      assert "confirm_delete_conversation" in events
      assert "cancel_delete_conversation" in events
      assert "delete_conversation" in events
    end
  end

  describe "handle_event toggle_select_conversation" do
    test "adds conversation to selection" do
      socket = build_socket(%{conversations_selected: MapSet.new()})

      {:noreply, socket} =
        ConversationsHandler.handle_event(
          "toggle_select_conversation",
          %{"id" => "c1"},
          socket
        )

      assert MapSet.member?(socket.assigns.conversations_selected, "c1")
    end

    test "removes conversation from selection" do
      socket = build_socket(%{conversations_selected: MapSet.new(["c1"])})

      {:noreply, socket} =
        ConversationsHandler.handle_event(
          "toggle_select_conversation",
          %{"id" => "c1"},
          socket
        )

      refute MapSet.member?(socket.assigns.conversations_selected, "c1")
    end
  end

  describe "handle_event toggle_select_all_conversations" do
    test "selects all when none selected" do
      convs = [%{id: "c1"}, %{id: "c2"}]

      socket =
        build_socket(%{
          managed_conversations: convs,
          conversations_selected: MapSet.new()
        })

      {:noreply, socket} =
        ConversationsHandler.handle_event("toggle_select_all_conversations", %{}, socket)

      assert MapSet.equal?(socket.assigns.conversations_selected, MapSet.new(["c1", "c2"]))
    end

    test "deselects all when all selected" do
      convs = [%{id: "c1"}, %{id: "c2"}]

      socket =
        build_socket(%{
          managed_conversations: convs,
          conversations_selected: MapSet.new(["c1", "c2"])
        })

      {:noreply, socket} =
        ConversationsHandler.handle_event("toggle_select_all_conversations", %{}, socket)

      assert MapSet.size(socket.assigns.conversations_selected) == 0
    end

    test "selects all when partially selected" do
      convs = [%{id: "c1"}, %{id: "c2"}]

      socket =
        build_socket(%{
          managed_conversations: convs,
          conversations_selected: MapSet.new(["c1"])
        })

      {:noreply, socket} =
        ConversationsHandler.handle_event("toggle_select_all_conversations", %{}, socket)

      assert MapSet.equal?(socket.assigns.conversations_selected, MapSet.new(["c1", "c2"]))
    end
  end

  describe "handle_event confirm/cancel bulk archive" do
    test "confirm sets confirm_bulk_delete to true" do
      socket = build_socket(%{confirm_bulk_delete: false})

      {:noreply, socket} =
        ConversationsHandler.handle_event("confirm_bulk_archive", %{}, socket)

      assert socket.assigns.confirm_bulk_delete == true
    end

    test "cancel sets confirm_bulk_delete to false" do
      socket = build_socket(%{confirm_bulk_delete: true})

      {:noreply, socket} =
        ConversationsHandler.handle_event("cancel_bulk_archive", %{}, socket)

      assert socket.assigns.confirm_bulk_delete == false
    end
  end

  describe "handle_event confirm/cancel delete conversation" do
    test "confirm sets confirm_delete_id" do
      socket = build_socket(%{confirm_delete_id: nil})

      {:noreply, socket} =
        ConversationsHandler.handle_event(
          "confirm_delete_conversation",
          %{"id" => "c1"},
          socket
        )

      assert socket.assigns.confirm_delete_id == "c1"
    end

    test "cancel clears confirm_delete_id" do
      socket = build_socket(%{confirm_delete_id: "c1"})

      {:noreply, socket} =
        ConversationsHandler.handle_event("cancel_delete_conversation", %{}, socket)

      assert socket.assigns.confirm_delete_id == nil
    end
  end

  # --- Test helpers ---

  defp build_socket(extra_assigns) do
    base = %{
      __changed__: %{},
      managed_conversations: [],
      conversations_page: 1,
      conversations_search: "",
      conversations_total: 0,
      conversations_selected: MapSet.new(),
      conversations_page_size: 20,
      confirm_bulk_delete: false,
      confirm_delete_id: nil,
      conversations: [],
      flash: %{}
    }

    assigns = Map.merge(base, extra_assigns)
    %Phoenix.LiveView.Socket{assigns: assigns}
  end
end
