defmodule LiteskillWeb.ChatLive.SourcesHandlerTest do
  use ExUnit.Case, async: true

  alias LiteskillWeb.ChatLive.SourcesHandler

  describe "assigns/0" do
    test "returns expected default assigns" do
      assigns = SourcesHandler.assigns()
      assert Keyword.get(assigns, :show_sources_sidebar) == false
      assert Keyword.get(assigns, :sidebar_sources) == []
      assert Keyword.get(assigns, :show_source_modal) == false
      assert Keyword.get(assigns, :source_modal_data) == %{}
      assert Keyword.get(assigns, :show_raw_output_modal) == false
      assert Keyword.get(assigns, :raw_output_message_id) == nil
      assert Keyword.get(assigns, :raw_output_content) == ""
    end
  end

  describe "events/0" do
    test "returns list of event names" do
      events = SourcesHandler.events()
      assert "toggle_sources_sidebar" in events
      assert "close_sources_sidebar" in events
      assert "show_source_modal" in events
      assert "close_source_modal" in events
      assert "show_raw_output_modal" in events
      assert "close_raw_output_modal" in events
      assert "raw_output_copied" in events
      assert "show_source" in events
    end
  end

  describe "find_source_by_doc_id/2" do
    test "finds source by document_id in assistant messages" do
      messages = [
        %{role: "user", rag_sources: nil},
        %{
          role: "assistant",
          rag_sources: [
            %{"document_id" => "doc-1", "content" => "found it"}
          ]
        }
      ]

      {source, _sources} = SourcesHandler.find_source_by_doc_id(messages, "doc-1")
      assert source["content"] == "found it"
    end

    test "returns {nil, []} when not found" do
      messages = [%{role: "user", rag_sources: nil}]
      assert SourcesHandler.find_source_by_doc_id(messages, "doc-1") == {nil, []}
    end

    test "returns {nil, []} for empty messages" do
      assert SourcesHandler.find_source_by_doc_id([], "doc-1") == {nil, []}
    end

    test "skips user messages" do
      messages = [
        %{
          role: "user",
          rag_sources: [%{"document_id" => "doc-1", "content" => "wrong"}]
        }
      ]

      assert SourcesHandler.find_source_by_doc_id(messages, "doc-1") == {nil, []}
    end
  end

  describe "handle_event toggle_sources_sidebar" do
    test "opens sidebar when message has rag_sources" do
      socket =
        build_socket(%{
          messages: [%{id: "m1", rag_sources: [%{"chunk_id" => "c1"}]}],
          show_sources_sidebar: false
        })

      {:noreply, socket} =
        SourcesHandler.handle_event(
          "toggle_sources_sidebar",
          %{"message-id" => "m1"},
          socket
        )

      assert socket.assigns.show_sources_sidebar == true
      assert socket.assigns.sidebar_sources == [%{"chunk_id" => "c1"}]
    end

    test "closes sidebar when already open" do
      socket =
        build_socket(%{
          messages: [%{id: "m1", rag_sources: [%{"chunk_id" => "c1"}]}],
          show_sources_sidebar: true,
          sidebar_sources: [%{"chunk_id" => "c1"}]
        })

      {:noreply, socket} =
        SourcesHandler.handle_event(
          "toggle_sources_sidebar",
          %{"message-id" => "m1"},
          socket
        )

      assert socket.assigns.show_sources_sidebar == false
      assert socket.assigns.sidebar_sources == []
    end

    test "no-op when message has no rag_sources" do
      socket =
        build_socket(%{
          messages: [%{id: "m1", rag_sources: nil}],
          show_sources_sidebar: false
        })

      {:noreply, result} =
        SourcesHandler.handle_event(
          "toggle_sources_sidebar",
          %{"message-id" => "m1"},
          socket
        )

      assert result.assigns.show_sources_sidebar == false
    end

    test "no-op when message not found" do
      socket = build_socket(%{messages: [], show_sources_sidebar: false})

      {:noreply, result} =
        SourcesHandler.handle_event(
          "toggle_sources_sidebar",
          %{"message-id" => "m1"},
          socket
        )

      assert result.assigns.show_sources_sidebar == false
    end
  end

  describe "handle_event close_sources_sidebar" do
    test "closes sidebar" do
      socket =
        build_socket(%{
          show_sources_sidebar: true,
          sidebar_sources: [%{"chunk_id" => "c1"}]
        })

      {:noreply, socket} = SourcesHandler.handle_event("close_sources_sidebar", %{}, socket)

      assert socket.assigns.show_sources_sidebar == false
      assert socket.assigns.sidebar_sources == []
    end
  end

  describe "handle_event show_source_modal" do
    test "opens modal with matching source" do
      source = %{"chunk_id" => "c1", "content" => "test"}
      socket = build_socket(%{sidebar_sources: [source], show_source_modal: false})

      {:noreply, socket} =
        SourcesHandler.handle_event(
          "show_source_modal",
          %{"chunk-id" => "c1"},
          socket
        )

      assert socket.assigns.show_source_modal == true
      assert socket.assigns.source_modal_data == source
    end

    test "no-op when source not found" do
      socket = build_socket(%{sidebar_sources: [], show_source_modal: false})

      {:noreply, socket} =
        SourcesHandler.handle_event(
          "show_source_modal",
          %{"chunk-id" => "c1"},
          socket
        )

      assert socket.assigns.show_source_modal == false
    end
  end

  describe "handle_event close_source_modal" do
    test "closes modal" do
      socket = build_socket(%{show_source_modal: true})

      {:noreply, socket} = SourcesHandler.handle_event("close_source_modal", %{}, socket)

      assert socket.assigns.show_source_modal == false
    end
  end

  describe "handle_event show_raw_output_modal" do
    test "opens modal with assistant message content" do
      socket =
        build_socket(%{
          messages: [%{id: "m1", role: "assistant", content: "Hello world"}],
          show_raw_output_modal: false
        })

      {:noreply, socket} =
        SourcesHandler.handle_event(
          "show_raw_output_modal",
          %{"message-id" => "m1"},
          socket
        )

      assert socket.assigns.show_raw_output_modal == true
      assert socket.assigns.raw_output_message_id == "m1"
      assert socket.assigns.raw_output_content == "Hello world"
    end

    test "no-op for user messages" do
      socket =
        build_socket(%{
          messages: [%{id: "m1", role: "user", content: "Hello"}],
          show_raw_output_modal: false
        })

      {:noreply, socket} =
        SourcesHandler.handle_event(
          "show_raw_output_modal",
          %{"message-id" => "m1"},
          socket
        )

      assert socket.assigns.show_raw_output_modal == false
    end

    test "no-op for empty content" do
      socket =
        build_socket(%{
          messages: [%{id: "m1", role: "assistant", content: ""}],
          show_raw_output_modal: false
        })

      {:noreply, socket} =
        SourcesHandler.handle_event(
          "show_raw_output_modal",
          %{"message-id" => "m1"},
          socket
        )

      assert socket.assigns.show_raw_output_modal == false
    end
  end

  describe "handle_event close_raw_output_modal" do
    test "closes modal and clears data" do
      socket =
        build_socket(%{
          show_raw_output_modal: true,
          raw_output_message_id: "m1",
          raw_output_content: "text"
        })

      {:noreply, socket} = SourcesHandler.handle_event("close_raw_output_modal", %{}, socket)

      assert socket.assigns.show_raw_output_modal == false
      assert socket.assigns.raw_output_message_id == nil
      assert socket.assigns.raw_output_content == ""
    end
  end

  # --- Test helpers ---

  defp build_socket(extra_assigns) do
    base = %{
      __changed__: %{},
      messages: [],
      show_sources_sidebar: false,
      sidebar_sources: [],
      show_source_modal: false,
      source_modal_data: %{},
      show_raw_output_modal: false,
      raw_output_message_id: nil,
      raw_output_content: "",
      flash: %{}
    }

    assigns = Map.merge(base, extra_assigns)
    %Phoenix.LiveView.Socket{assigns: assigns}
  end
end
