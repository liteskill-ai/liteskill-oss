defmodule LiteskillWeb.ChatLive.SourcesHandler do
  @moduledoc false

  use LiteskillWeb, :html

  import Phoenix.LiveView, only: [put_flash: 3]

  def assigns do
    [
      show_sources_sidebar: false,
      sidebar_sources: [],
      show_source_modal: false,
      source_modal_data: %{},
      show_raw_output_modal: false,
      raw_output_message_id: nil,
      raw_output_content: ""
    ]
  end

  @events ~w(toggle_sources_sidebar close_sources_sidebar show_source_modal
    close_source_modal show_raw_output_modal close_raw_output_modal
    raw_output_copied show_source)

  def events, do: @events

  def handle_event("toggle_sources_sidebar", %{"message-id" => message_id}, socket) do
    message = Enum.find(socket.assigns.messages, &(&1.id == message_id))

    if message && message.rag_sources not in [nil, []] do
      if socket.assigns.show_sources_sidebar do
        {:noreply, assign(socket, show_sources_sidebar: false, sidebar_sources: [])}
      else
        {:noreply, assign(socket, show_sources_sidebar: true, sidebar_sources: message.rag_sources)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_sources_sidebar", _params, socket) do
    {:noreply, assign(socket, show_sources_sidebar: false, sidebar_sources: [])}
  end

  def handle_event("show_source_modal", %{"chunk-id" => chunk_id}, socket) do
    source = Enum.find(socket.assigns.sidebar_sources, &(&1["chunk_id"] == chunk_id))

    if source do
      {:noreply, assign(socket, show_source_modal: true, source_modal_data: source)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_source_modal", _params, socket) do
    {:noreply, assign(socket, show_source_modal: false)}
  end

  def handle_event("show_raw_output_modal", %{"message-id" => message_id}, socket) do
    message =
      Enum.find(socket.assigns.messages, fn msg ->
        msg.id == message_id && msg.role == "assistant"
      end)

    if message && message.content not in [nil, ""] do
      {:noreply,
       assign(socket,
         show_raw_output_modal: true,
         raw_output_message_id: message_id,
         raw_output_content: message.content
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_raw_output_modal", _params, socket) do
    {:noreply,
     assign(socket,
       show_raw_output_modal: false,
       raw_output_message_id: nil,
       raw_output_content: ""
     )}
  end

  def handle_event("raw_output_copied", _params, socket) do
    {:noreply, put_flash(socket, :info, "Raw output copied")}
  end

  def handle_event("show_source", %{"doc-id" => doc_id}, socket) do
    {source, _msg_sources} = find_source_by_doc_id(socket.assigns.messages, doc_id)

    source_data =
      source || lookup_source_from_db(doc_id, socket.assigns.current_user.id)

    if source_data do
      {:noreply,
       assign(socket,
         show_source_modal: true,
         source_modal_data: source_data
       )}
    else
      {:noreply, socket}
    end
  end

  # --- Private helpers ---

  def find_source_by_doc_id(messages, doc_id) do
    msg =
      Enum.find(messages, fn m ->
        m.role == "assistant" && m.rag_sources &&
          Enum.any?(m.rag_sources, &(&1["document_id"] == doc_id))
      end)

    if msg do
      source = Enum.find(msg.rag_sources, &(&1["document_id"] == doc_id))
      {source, msg.rag_sources}
    else
      {nil, []}
    end
  end

  def lookup_source_from_db(doc_id, user_id) do
    alias Liteskill.Rag

    case Rag.get_document_with_source(doc_id, user_id) do
      {:ok, doc} ->
        wiki_doc_id = get_in(doc.metadata || %{}, ["wiki_document_id"])

        %{
          "chunk_id" => nil,
          "document_id" => doc.id,
          "document_title" => doc.title,
          "source_name" => doc.source.name,
          "content" => doc.content,
          "position" => nil,
          "relevance_score" => nil,
          "source_uri" => if(wiki_doc_id, do: "/wiki/#{wiki_doc_id}")
        }

      _ ->
        nil
    end
  end
end
