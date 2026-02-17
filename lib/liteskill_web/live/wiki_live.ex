defmodule LiteskillWeb.WikiLive do
  @moduledoc """
  Standalone LiveView for the Wiki feature.
  """

  use LiteskillWeb, :live_view

  alias Liteskill.Chat
  alias LiteskillWeb.{ChatComponents, SharingComponents, SharingLive, WikiComponents}
  alias LiteskillWeb.Layouts

  @sharing_events SharingLive.sharing_events()

  @impl true
  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_user.id
    has_admin_access = Liteskill.Rbac.has_any_admin_permission?(user_id)
    conversations = Chat.list_conversations(user_id)

    {:ok,
     socket
     |> assign(
       sidebar_open: true,
       conversations: conversations,
       wiki_document: nil,
       wiki_tree: [],
       wiki_sidebar_tree: [],
       wiki_sidebar_open: true,
       wiki_form: to_form(%{"title" => "", "content" => ""}, as: :wiki_page),
       show_wiki_form: false,
       wiki_editing: nil,
       wiki_parent_id: nil,
       wiki_space: nil,
       wiki_user_role: nil,
       wiki_view_mode: "card",
       current_source: get_wiki_source(),
       source_documents: %{documents: [], page: 1, page_size: 20, total: 0, total_pages: 1},
       source_search: "",
       has_admin_access: has_admin_access
     )
     |> assign(SharingLive.sharing_assigns()), layout: {LiteskillWeb.Layouts, :chat}}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> push_event("nav", %{})
     |> push_accent_color()
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp push_accent_color(socket) do
    color = Liteskill.Accounts.User.accent_color(socket.assigns.current_user)
    push_event(socket, "set-accent", %{color: color})
  end

  defp apply_action(socket, :wiki, _params) do
    user_id = socket.assigns.current_user.id

    result =
      Liteskill.DataSources.list_documents_paginated("builtin:wiki", user_id,
        page: 1,
        search: nil,
        parent_id: nil
      )

    enriched_docs =
      Enum.map(result.documents, fn space ->
        if space.user_id == user_id do
          Map.put(space, :space_role, "owner")
        else
          case Liteskill.Authorization.get_role("wiki_space", space.id, user_id) do
            {:ok, role} -> Map.put(space, :space_role, role)
            _ -> Map.put(space, :space_role, nil)
          end
        end
      end)

    assign(socket,
      current_source: get_wiki_source(),
      source_documents: %{result | documents: enriched_docs},
      source_search: "",
      wiki_document: nil,
      wiki_sidebar_tree: [],
      wiki_space: nil,
      wiki_user_role: nil,
      page_title: "Wiki"
    )
  end

  defp apply_action(socket, :wiki_page_show, %{"document_id" => doc_id}) do
    user_id = socket.assigns.current_user.id

    case Liteskill.DataSources.get_document_with_role(doc_id, user_id) do
      {:ok, doc, role} ->
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

        assign(socket,
          current_source: get_wiki_source(),
          wiki_document: doc,
          wiki_tree: space_children_tree,
          wiki_sidebar_tree: space_children_tree,
          wiki_space: space,
          wiki_user_role: role,
          show_wiki_form: false,
          wiki_editing: nil,
          wiki_parent_id: nil,
          page_title: doc.title
        )

      {:error, _} ->
        socket
        |> put_flash(:error, "Page not found")
        |> push_navigate(to: ~p"/wiki")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen relative">
      <Layouts.sidebar
        sidebar_open={@sidebar_open}
        live_action={@live_action}
        conversations={@conversations}
        active_conversation_id={nil}
        current_user={@current_user}
        has_admin_access={@has_admin_access}
      />

      <%!-- Main Area --%>
      <main class="flex-1 flex flex-col min-w-0">
        <%= if @live_action == :wiki do %>
          <%!-- Wiki Home — Spaces --%>
          <header class="px-4 py-3 border-b border-base-300 flex-shrink-0">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-2">
                <button
                  :if={!@sidebar_open}
                  phx-click="toggle_sidebar"
                  class="btn btn-circle btn-ghost btn-sm"
                >
                  <.icon name="hero-bars-3-micro" class="size-5" />
                </button>
                <h1 class="text-xl tracking-wide" style="font-family: 'Bebas Neue', sans-serif;">
                  Wiki
                </h1>
              </div>
              <div class="flex items-center gap-2">
                <div class="join">
                  <button
                    phx-click="toggle_wiki_view_mode"
                    phx-value-mode="card"
                    class={"join-item btn btn-xs #{if @wiki_view_mode == "card", do: "btn-active", else: "btn-ghost"}"}
                    title="Card view"
                  >
                    <.icon name="hero-squares-2x2-micro" class="size-3.5" />
                  </button>
                  <button
                    phx-click="toggle_wiki_view_mode"
                    phx-value-mode="list"
                    class={"join-item btn btn-xs #{if @wiki_view_mode == "list", do: "btn-active", else: "btn-ghost"}"}
                    title="List view"
                  >
                    <.icon name="hero-bars-4-micro" class="size-3.5" />
                  </button>
                </div>
                <button phx-click="show_wiki_form" class="btn btn-primary btn-sm gap-1">
                  <.icon name="hero-plus-micro" class="size-4" /> New Space
                </button>
              </div>
            </div>
          </header>

          <div class="flex-1 overflow-y-auto p-4 max-w-4xl mx-auto w-full">
            <div
              :if={@source_documents.documents != [] && @wiki_view_mode == "card"}
              class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4"
            >
              <WikiComponents.space_card
                :for={space <- @source_documents.documents}
                space={space}
                space_role={Map.get(space, :space_role)}
              />
            </div>
            <div
              :if={@source_documents.documents != [] && @wiki_view_mode == "list"}
              class="space-y-1"
            >
              <WikiComponents.space_list_item
                :for={space <- @source_documents.documents}
                space={space}
                space_role={Map.get(space, :space_role)}
              />
            </div>
            <p
              :if={@source_documents.documents == []}
              class="text-base-content/50 text-center py-12 text-sm"
            >
              No spaces yet. Create your first space to get started.
            </p>

            <div :if={@source_documents.total_pages > 1} class="flex justify-center gap-1 pt-4">
              <button
                :if={@source_documents.page > 1}
                phx-click="source_page"
                phx-value-page={@source_documents.page - 1}
                class="btn btn-ghost btn-xs"
              >
                Previous
              </button>
              <span class="btn btn-ghost btn-xs no-animation">
                {@source_documents.page} / {@source_documents.total_pages}
              </span>
              <button
                :if={@source_documents.page < @source_documents.total_pages}
                phx-click="source_page"
                phx-value-page={@source_documents.page + 1}
                class="btn btn-ghost btn-xs"
              >
                Next
              </button>
            </div>
          </div>

          <ChatComponents.modal
            id="wiki-form-modal"
            title="New Space"
            show={@show_wiki_form}
            on_close="close_wiki_form"
          >
            <.form for={@wiki_form} phx-submit="create_wiki_page" class="space-y-4">
              <div class="form-control">
                <label class="label"><span class="label-text">Space Name *</span></label>
                <input
                  type="text"
                  name="wiki_page[title]"
                  value={Phoenix.HTML.Form.input_value(@wiki_form, :title)}
                  class="input input-bordered w-full"
                  required
                />
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">Description (Markdown)</span></label>
                <textarea
                  name="wiki_page[content]"
                  class="textarea textarea-bordered w-full font-mono text-sm"
                  rows="6"
                >{Phoenix.HTML.Form.input_value(@wiki_form, :content)}</textarea>
              </div>
              <div class="flex justify-end gap-2 pt-2">
                <button type="button" phx-click="close_wiki_form" class="btn btn-ghost btn-sm">
                  Cancel
                </button>
                <button type="submit" class="btn btn-primary btn-sm">Create Space</button>
              </div>
            </.form>
          </ChatComponents.modal>
        <% end %>
        <%= if @live_action == :wiki_page_show && @wiki_document do %>
          <%!-- Wiki Page Detail --%>
          <header class="px-4 py-3 border-b border-base-300 flex-shrink-0">
            <div class="flex flex-wrap items-center justify-between gap-2">
              <div class="flex items-center gap-2 min-w-0">
                <button
                  :if={!@sidebar_open}
                  phx-click="toggle_sidebar"
                  class="btn btn-circle btn-ghost btn-sm"
                >
                  <.icon name="hero-bars-3-micro" class="size-5" />
                </button>
                <.link
                  navigate={
                    if is_nil(@wiki_document.parent_document_id),
                      do: ~p"/wiki",
                      else: ~p"/wiki/#{@wiki_document.parent_document_id}"
                  }
                  class="btn btn-ghost btn-xs"
                >
                  <.icon name="hero-arrow-left-micro" class="size-4" />
                </.link>
                <h1
                  class="text-xl tracking-wide truncate"
                  style="font-family: 'Bebas Neue', sans-serif;"
                >
                  {@wiki_document.title}
                </h1>
              </div>
              <div :if={!@wiki_editing} class="flex gap-1">
                <button
                  :if={@wiki_user_role in ["editor", "manager", "owner"]}
                  phx-click="edit_wiki_page"
                  class="btn btn-ghost btn-sm gap-1"
                >
                  <.icon name="hero-pencil-square-micro" class="size-4" /> Edit
                </button>
                <button
                  :if={@wiki_user_role in ["editor", "manager", "owner"]}
                  phx-click="show_wiki_form"
                  phx-value-parent-id={@wiki_document.id}
                  class="btn btn-ghost btn-sm gap-1"
                >
                  <.icon name="hero-plus-micro" class="size-4" /> Add Child
                </button>
                <button
                  :if={@wiki_user_role in ["manager", "owner"] && @wiki_space}
                  phx-click="open_sharing"
                  phx-value-entity-type="wiki_space"
                  phx-value-entity-id={@wiki_space.id}
                  class="btn btn-ghost btn-sm gap-1"
                >
                  <.icon name="hero-share-micro" class="size-4" /> Share
                </button>
                <button
                  :if={@wiki_user_role in ["manager", "owner"]}
                  phx-click="delete_wiki_page"
                  data-confirm="Delete this page and all children?"
                  class="btn btn-ghost btn-sm text-error gap-1"
                >
                  <.icon name="hero-trash-micro" class="size-4" /> Delete
                </button>
              </div>
            </div>
          </header>

          <div class="flex flex-1 min-h-0 overflow-hidden">
            <%= if @wiki_sidebar_tree != [] && @wiki_space do %>
              <%= if @wiki_sidebar_open do %>
                <aside class="w-56 flex-shrink-0 border-r border-base-300 overflow-y-auto bg-base-200/50">
                  <div class="p-3 min-w-56">
                    <div class="flex items-center justify-between mb-2">
                      <.link
                        navigate={~p"/wiki/#{@wiki_space.id}"}
                        class="text-xs font-semibold text-base-content/50 uppercase tracking-wider hover:text-primary transition-colors truncate"
                      >
                        {@wiki_space.title}
                      </.link>
                      <button
                        phx-click="toggle_wiki_sidebar"
                        class="btn btn-ghost btn-xs btn-circle"
                        title="Collapse sidebar"
                      >
                        <.icon name="hero-chevron-left-micro" class="size-3.5" />
                      </button>
                    </div>
                    <WikiComponents.wiki_tree_sidebar
                      tree={@wiki_sidebar_tree}
                      active_doc_id={if @wiki_document, do: @wiki_document.id, else: nil}
                    />
                  </div>
                </aside>
              <% else %>
                <div class="flex-shrink-0 border-r border-base-300 bg-base-200/50 flex items-start pt-2 px-1">
                  <button
                    phx-click="toggle_wiki_sidebar"
                    class="btn btn-ghost btn-xs btn-circle"
                    title="Show wiki nav"
                  >
                    <.icon name="hero-chevron-right-micro" class="size-3.5" />
                  </button>
                </div>
              <% end %>
            <% end %>
            <div class="flex-1 min-w-0 flex flex-col">
              <%= if @wiki_editing do %>
                <div class="flex-1 overflow-y-auto px-6 py-6 max-w-3xl mx-auto w-full">
                  <.form for={@wiki_form} phx-submit="update_wiki_page" class="space-y-4">
                    <div class="form-control">
                      <input
                        type="text"
                        name="wiki_page[title]"
                        value={Phoenix.HTML.Form.input_value(@wiki_form, :title)}
                        class="input input-bordered w-full text-lg font-semibold"
                        required
                      />
                    </div>
                    <input
                      type="hidden"
                      name="wiki_page[content]"
                      data-editor-content
                      value={Phoenix.HTML.Form.input_value(@wiki_form, :content)}
                    />
                    <div
                      id="wiki-editor"
                      phx-hook="WikiEditor"
                      phx-update="ignore"
                      data-content={Phoenix.HTML.Form.input_value(@wiki_form, :content)}
                      class="border border-base-300 rounded-lg overflow-hidden"
                    >
                      <div data-editor-target class="min-h-[300px]"></div>
                    </div>
                    <div class="flex justify-end gap-2 pt-2">
                      <button
                        type="button"
                        phx-click="cancel_wiki_edit"
                        class="btn btn-ghost btn-sm"
                      >
                        Cancel
                      </button>
                      <button type="submit" class="btn btn-primary btn-sm">Save</button>
                    </div>
                  </.form>
                </div>
              <% else %>
                <div class="flex-1 overflow-y-auto px-6 py-6 max-w-3xl mx-auto w-full space-y-6">
                  <div
                    :if={@wiki_document.content && @wiki_document.content != ""}
                    id="wiki-content"
                    phx-hook="CopyCode"
                    class="prose prose-sm max-w-none"
                  >
                    {LiteskillWeb.Markdown.render(@wiki_document.content)}
                  </div>
                  <p
                    :if={!@wiki_document.content || @wiki_document.content == ""}
                    class="text-base-content/50 text-center py-8"
                  >
                    This page has no content yet. Click "Edit" to add some.
                  </p>

                  <WikiComponents.wiki_children
                    source={@current_source}
                    document={@wiki_document}
                    tree={@wiki_tree}
                  />
                </div>
              <% end %>
            </div>
          </div>

          <ChatComponents.modal
            id="wiki-page-modal"
            title="New Child Page"
            show={@show_wiki_form}
            on_close="close_wiki_form"
          >
            <.form for={@wiki_form} phx-submit="create_wiki_page" class="space-y-4">
              <div class="form-control">
                <label class="label"><span class="label-text">Title *</span></label>
                <input
                  type="text"
                  name="wiki_page[title]"
                  value={Phoenix.HTML.Form.input_value(@wiki_form, :title)}
                  class="input input-bordered w-full"
                  required
                />
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">Content (Markdown)</span></label>
                <input
                  type="hidden"
                  name="wiki_page[content]"
                  data-editor-content
                  value={Phoenix.HTML.Form.input_value(@wiki_form, :content)}
                />
                <div
                  id="wiki-child-editor"
                  phx-hook="WikiEditor"
                  phx-update="ignore"
                  data-content={Phoenix.HTML.Form.input_value(@wiki_form, :content)}
                  class="border border-base-300 rounded-lg overflow-hidden"
                >
                  <div data-editor-target class="min-h-[200px]"></div>
                </div>
              </div>
              <div class="flex justify-end gap-2 pt-2">
                <button type="button" phx-click="close_wiki_form" class="btn btn-ghost btn-sm">
                  Cancel
                </button>
                <button type="submit" class="btn btn-primary btn-sm">Create</button>
              </div>
            </.form>
          </ChatComponents.modal>
        <% end %>
      </main>

      <SharingComponents.sharing_modal
        show={@show_sharing}
        entity_type={@sharing_entity_type || "wiki_space"}
        entity_id={@sharing_entity_id}
        acls={@sharing_acls}
        user_search_results={@sharing_user_search_results}
        user_search_query={@sharing_user_search_query}
        groups={@sharing_groups}
        current_user_id={@current_user.id}
        error={@sharing_error}
      />
    </div>
    """
  end

  # --- Event Handlers ---

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, sidebar_open: !socket.assigns.sidebar_open)}
  end

  def handle_event("toggle_wiki_sidebar", _params, socket) do
    {:noreply, assign(socket, wiki_sidebar_open: !socket.assigns.wiki_sidebar_open)}
  end

  def handle_event("toggle_wiki_view_mode", %{"mode" => mode}, socket)
      when mode in ["card", "list"] do
    {:noreply, assign(socket, wiki_view_mode: mode)}
  end

  def handle_event("select_conversation", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/c/#{id}")}
  end

  def handle_event("confirm_delete_conversation", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("show_wiki_form", params, socket) do
    parent_id = params["parent-id"]

    {:noreply,
     assign(socket,
       show_wiki_form: true,
       wiki_parent_id: parent_id,
       wiki_editing: nil,
       wiki_form: to_form(%{"title" => "", "content" => ""}, as: :wiki_page)
     )}
  end

  def handle_event("close_wiki_form", _params, socket) do
    {:noreply, assign(socket, show_wiki_form: false, wiki_editing: nil)}
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
        {:noreply,
         socket
         |> assign(show_wiki_form: false)
         |> push_navigate(to: ~p"/wiki/#{doc.id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("create page", reason))}
    end
  end

  def handle_event("edit_wiki_page", _params, socket) do
    doc = socket.assigns.wiki_document

    {:noreply,
     assign(socket,
       wiki_editing: doc,
       wiki_form: to_form(%{"title" => doc.title, "content" => doc.content || ""}, as: :wiki_page)
     )}
  end

  def handle_event("cancel_wiki_edit", _params, socket) do
    {:noreply, assign(socket, wiki_editing: nil)}
  end

  def handle_event("update_wiki_page", %{"wiki_page" => params}, socket) do
    user_id = socket.assigns.current_user.id
    doc = socket.assigns.wiki_editing

    attrs = %{title: String.trim(params["title"]), content: params["content"] || ""}

    case Liteskill.DataSources.update_document(doc.id, attrs, user_id) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(show_wiki_form: false, wiki_editing: nil, wiki_document: updated)
         |> reload_wiki_page()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("update page", reason))}
    end
  end

  def handle_event("delete_wiki_page", _params, socket) do
    user_id = socket.assigns.current_user.id
    doc = socket.assigns.wiki_document

    case Liteskill.DataSources.delete_document(doc.id, user_id) do
      {:ok, _} ->
        redirect_to =
          if doc.parent_document_id,
            do: ~p"/wiki/#{doc.parent_document_id}",
            else: ~p"/wiki"

        {:noreply, push_navigate(socket, to: redirect_to)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("delete page", reason))}
    end
  end

  def handle_event("source_page", %{"page" => page}, socket) do
    user_id = socket.assigns.current_user.id
    search = socket.assigns.source_search

    result =
      Liteskill.DataSources.list_documents_paginated("builtin:wiki", user_id,
        page: safe_page(page),
        search: if(search == "", do: nil, else: search)
      )

    {:noreply, assign(socket, source_documents: result)}
  end

  # Sharing event delegation
  def handle_event(event, params, socket) when event in @sharing_events do
    SharingLive.handle_event(event, params, socket)
  end

  # --- Helpers ---

  defp reload_wiki_page(socket) do
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

        assign(socket, wiki_document: doc, wiki_tree: tree, wiki_sidebar_tree: tree)

      # coveralls-ignore-start
      {:error, _} ->
        socket
        # coveralls-ignore-stop
    end
  end

  defp get_wiki_source, do: Liteskill.BuiltinSources.find("builtin:wiki")

  defp safe_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {n, _} when n > 0 -> n
      _ -> 1
    end
  end

  defp safe_page(page) when is_integer(page) and page > 0, do: page
  defp safe_page(_), do: 1
end
