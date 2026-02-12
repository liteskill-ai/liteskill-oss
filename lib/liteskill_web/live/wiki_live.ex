defmodule LiteskillWeb.WikiLive do
  @moduledoc """
  Wiki event handlers and helpers, rendered within ChatLive's main area.
  """

  use LiteskillWeb, :html

  @wiki_actions [:wiki, :wiki_page_show]

  def wiki_action?(action), do: action in @wiki_actions

  def wiki_assigns do
    [
      wiki_document: nil,
      wiki_tree: [],
      wiki_sidebar_tree: [],
      wiki_form: to_form(%{"title" => "", "content" => ""}, as: :wiki_page),
      show_wiki_form: false,
      wiki_editing: nil,
      wiki_parent_id: nil,
      wiki_space: nil,
      show_wiki_export_modal: false,
      wiki_export_title: "",
      wiki_export_parent_id: nil,
      wiki_export_tree: []
    ]
  end

  def apply_wiki_action(socket, :wiki, _params) do
    user_id = socket.assigns.current_user.id

    result =
      Liteskill.DataSources.list_documents_paginated("builtin:wiki", user_id,
        page: 1,
        search: nil,
        parent_id: nil
      )

    Phoenix.Component.assign(socket,
      conversation: nil,
      messages: [],
      streaming: false,
      stream_content: "",
      pending_tool_calls: [],
      current_source: get_wiki_source(),
      source_documents: result,
      source_search: "",
      wiki_sidebar_tree: [],
      wiki_space: nil,
      page_title: "Wiki"
    )
  end

  def apply_wiki_action(socket, :wiki_page_show, %{"document_id" => doc_id}) do
    user_id = socket.assigns.current_user.id

    case Liteskill.DataSources.get_document(doc_id, user_id) do
      {:ok, doc} ->
        space =
          if is_nil(doc.parent_document_id) do
            doc
          else
            case Liteskill.DataSources.find_root_ancestor(doc.id, user_id) do
              {:ok, root} -> root
              _ -> nil
            end
          end

        space_children_tree =
          if space do
            Liteskill.DataSources.space_tree("builtin:wiki", space.id, user_id)
          else
            []
          end

        Phoenix.Component.assign(socket,
          conversation: nil,
          messages: [],
          streaming: false,
          stream_content: "",
          pending_tool_calls: [],
          current_source: get_wiki_source(),
          wiki_document: doc,
          wiki_tree: space_children_tree,
          wiki_sidebar_tree: space_children_tree,
          wiki_space: space,
          show_wiki_form: false,
          wiki_editing: nil,
          wiki_parent_id: nil,
          page_title: doc.title
        )

      {:error, _} ->
        socket
        |> Phoenix.LiveView.put_flash(:error, "Page not found")
        |> Phoenix.LiveView.push_navigate(to: ~p"/wiki")
    end
  end

  # --- Event Handlers (called from ChatLive) ---

  def handle_event("show_wiki_form", params, socket) do
    parent_id = params["parent-id"]

    {:noreply,
     Phoenix.Component.assign(socket,
       show_wiki_form: true,
       wiki_parent_id: parent_id,
       wiki_editing: nil,
       wiki_form: to_form(%{"title" => "", "content" => ""}, as: :wiki_page)
     )}
  end

  def handle_event("close_wiki_form", _params, socket) do
    {:noreply, Phoenix.Component.assign(socket, show_wiki_form: false, wiki_editing: nil)}
  end

  def handle_event("create_wiki_page", %{"wiki_page" => params}, socket) do
    user_id = socket.assigns.current_user.id
    source_ref = socket.assigns.current_source.id
    parent_id = socket.assigns.wiki_parent_id

    attrs = %{
      title: String.trim(params["title"]),
      content: params["content"] || "",
      content_type: "markdown"
    }

    result =
      if parent_id do
        Liteskill.DataSources.create_child_document(source_ref, parent_id, attrs, user_id)
      else
        Liteskill.DataSources.create_document(source_ref, attrs, user_id)
      end

    case result do
      {:ok, doc} ->
        enqueue_wiki_sync(doc.id, user_id, "upsert")

        {:noreply,
         socket
         |> Phoenix.Component.assign(show_wiki_form: false)
         |> Phoenix.LiveView.push_navigate(to: ~p"/wiki/#{doc.id}")}

      {:error, _} ->
        {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Failed to create page")}
    end
  end

  def handle_event("edit_wiki_page", _params, socket) do
    doc = socket.assigns.wiki_document

    {:noreply,
     Phoenix.Component.assign(socket,
       wiki_editing: doc,
       wiki_form: to_form(%{"title" => doc.title, "content" => doc.content || ""}, as: :wiki_page)
     )}
  end

  def handle_event("cancel_wiki_edit", _params, socket) do
    {:noreply, Phoenix.Component.assign(socket, wiki_editing: nil)}
  end

  def handle_event("update_wiki_page", %{"wiki_page" => params}, socket) do
    user_id = socket.assigns.current_user.id
    doc = socket.assigns.wiki_editing

    attrs = %{title: String.trim(params["title"]), content: params["content"] || ""}

    case Liteskill.DataSources.update_document(doc.id, attrs, user_id) do
      {:ok, updated} ->
        enqueue_wiki_sync(updated.id, user_id, "upsert")

        {:noreply,
         socket
         |> Phoenix.Component.assign(
           show_wiki_form: false,
           wiki_editing: nil,
           wiki_document: updated
         )
         |> reload_wiki_page()}

      {:error, _} ->
        {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Failed to update page")}
    end
  end

  def handle_event("delete_wiki_page", _params, socket) do
    user_id = socket.assigns.current_user.id
    doc = socket.assigns.wiki_document

    case Liteskill.DataSources.delete_document(doc.id, user_id) do
      {:ok, _} ->
        enqueue_wiki_sync(doc.id, user_id, "delete")

        redirect_to =
          if doc.parent_document_id,
            do: ~p"/wiki/#{doc.parent_document_id}",
            else: ~p"/wiki"

        {:noreply, Phoenix.LiveView.push_navigate(socket, to: redirect_to)}

      {:error, _} ->
        {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Failed to delete page")}
    end
  end

  def handle_event("open_wiki_export_modal", _params, socket) do
    user_id = socket.assigns.current_user.id
    tree = Liteskill.DataSources.document_tree("builtin:wiki", user_id)

    {:noreply,
     Phoenix.Component.assign(socket,
       show_wiki_export_modal: true,
       wiki_export_title: socket.assigns.report.title,
       wiki_export_parent_id: nil,
       wiki_export_tree: tree
     )}
  end

  def handle_event("close_wiki_export_modal", _params, socket) do
    {:noreply, Phoenix.Component.assign(socket, show_wiki_export_modal: false)}
  end

  def handle_event("confirm_wiki_export", %{"title" => title, "parent_id" => parent_id}, socket) do
    if parent_id == "" do
      {:noreply,
       Phoenix.LiveView.put_flash(socket, :error, "Please select a space for the wiki page")}
    else
      user_id = socket.assigns.current_user.id
      report = socket.assigns.report

      case Liteskill.DataSources.export_report_to_wiki(report.id, user_id,
             title: title,
             parent_id: parent_id
           ) do
        {:ok, doc} ->
          enqueue_wiki_sync(doc.id, user_id, "upsert")

          {:noreply,
           socket
           |> Phoenix.Component.assign(show_wiki_export_modal: false)
           |> Phoenix.LiveView.put_flash(:info, "Report exported to wiki")
           |> Phoenix.LiveView.push_navigate(to: ~p"/wiki/#{doc.id}")}

        {:error, _} ->
          {:noreply,
           Phoenix.LiveView.put_flash(socket, :error, "Failed to export report to wiki")}
      end
    end
  end

  # --- Helpers ---

  def reload_wiki_page(socket) do
    user_id = socket.assigns.current_user.id
    doc_id = socket.assigns.wiki_document.id

    case Liteskill.DataSources.get_document(doc_id, user_id) do
      {:ok, doc} ->
        space = socket.assigns.wiki_space

        tree =
          if space do
            Liteskill.DataSources.space_tree("builtin:wiki", space.id, user_id)
          else
            []
          end

        Phoenix.Component.assign(socket,
          wiki_document: doc,
          wiki_tree: tree,
          wiki_sidebar_tree: tree
        )

      # coveralls-ignore-start
      {:error, _} ->
        socket
        # coveralls-ignore-stop
    end
  end

  def get_wiki_source, do: Liteskill.BuiltinSources.find("builtin:wiki")

  def enqueue_wiki_sync(wiki_document_id, user_id, action) do
    Liteskill.Rag.WikiSyncWorker.new(%{
      "wiki_document_id" => wiki_document_id,
      "user_id" => user_id,
      "action" => action
    })
    |> Oban.insert()
  end
end
