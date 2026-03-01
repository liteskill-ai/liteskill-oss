defmodule LiteskillWeb.SourcesLive do
  @moduledoc """
  Standalone LiveView for data source management: browsing, configuring,
  syncing, and inspecting RAG-indexed documents.
  """

  use LiteskillWeb, :live_view

  alias Liteskill.Chat
  alias LiteskillWeb.ChatComponents
  alias LiteskillWeb.Layouts
  alias LiteskillWeb.SharingComponents
  alias LiteskillWeb.SharingLive
  alias LiteskillWeb.SourcesComponents
  alias LiteskillWeb.WikiComponents

  # --- Assigns ---

  def sources_assigns do
    [
      confirm_delete_source_id: nil,
      data_sources: [],
      current_source: nil,
      source_document: nil,
      rag_document: nil,
      rag_chunks: [],
      source_documents: %{documents: [], page: 1, page_size: 20, total: 0, total_pages: 1},
      source_search: "",
      # RAG query
      show_rag_query: false,
      rag_query_loading: false,
      rag_query_results: [],
      rag_query_collections: [],
      rag_query_error: nil,
      rag_enabled: true,
      # Source configuration modal
      show_configure_source: false,
      configure_source: nil,
      configure_source_fields: [],
      configure_source_form: to_form(%{}, as: :config),
      # Add source modal
      show_add_source: false,
      available_source_types: Liteskill.DataSources.available_source_types()
    ]
  end

  # --- LiveView callbacks ---

  @impl true
  def mount(_params, _session, socket) do
    conversations = Chat.list_conversations(socket.assigns.current_user.id)

    {:ok,
     socket
     |> assign(sources_assigns())
     |> assign(SharingLive.sharing_assigns())
     |> assign(
       conversations: conversations,
       conversation: nil,
       sidebar_open: true,
       has_admin_access: Liteskill.Rbac.has_any_admin_permission?(socket.assigns.current_user.id),
       single_user_mode: Liteskill.SingleUser.enabled?()
     ), layout: {Layouts, :chat}}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :sources, _params) do
    user_id = socket.assigns.current_user.id
    sources = Liteskill.DataSources.list_sources_with_counts(user_id)
    rag_collections = Liteskill.Rag.list_accessible_collections(user_id)

    assign(socket,
      conversation: nil,
      data_sources: sources,
      rag_query_collections: rag_collections,
      show_rag_query: false,
      rag_query_results: [],
      rag_query_loading: false,
      rag_query_error: nil,
      rag_enabled: Liteskill.Settings.embedding_enabled?(),
      page_title: "Data Sources"
    )
  end

  defp apply_action(socket, :source_show, %{"source_id" => source_url_id}) do
    user_id = socket.assigns.current_user.id
    source_id = source_id_from_url(source_url_id)

    case Liteskill.DataSources.get_source(source_id, user_id) do
      {:ok, source} ->
        source_ref = source.id

        result =
          Liteskill.DataSources.list_documents_paginated(source_ref, user_id,
            page: 1,
            search: nil
          )

        assign(socket,
          conversation: nil,
          current_source: source,
          source_documents: result,
          source_search: "",
          page_title: source.name
        )

      {:error, reason} ->
        socket
        |> put_flash(:error, action_error("load source", reason))
        |> push_navigate(to: ~p"/sources")
    end
  end

  defp apply_action(socket, :source_document_show, %{"source_id" => source_url_id, "document_id" => doc_id}) do
    user_id = socket.assigns.current_user.id
    source_id = source_id_from_url(source_url_id)

    with {:ok, source} <- Liteskill.DataSources.get_source(source_id, user_id),
         {:ok, doc} <- Liteskill.DataSources.get_document(doc_id, user_id) do
      {rag_doc, chunks} =
        case Liteskill.Rag.get_rag_document_for_source_doc(doc_id, user_id) do
          {:ok, rd} -> {rd, Liteskill.Rag.list_chunks_for_document(rd.id, user_id)}
          {:error, _} -> {nil, []}
        end

      assign(socket,
        conversation: nil,
        current_source: source,
        source_document: doc,
        rag_document: rag_doc,
        rag_chunks: chunks,
        page_title: doc.title
      )
    else
      {:error, reason} ->
        socket
        |> put_flash(:error, action_error("load document", reason))
        |> push_navigate(to: ~p"/sources")
    end
  end

  # --- Render ---

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
        single_user_mode={@single_user_mode}
      />

      <main class="flex-1 flex flex-col min-w-0">
        <%= if @live_action == :sources do %>
          <%!-- Data Sources --%>
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
                <h1 class="text-lg font-semibold">Data Sources</h1>
              </div>
              <.link navigate={~p"/sources/pipeline"} class="btn btn-ghost btn-sm gap-1">
                <.icon name="hero-chart-bar-micro" class="size-4" /> Pipeline
              </.link>
              <button phx-click="open_rag_query" class="btn btn-ghost btn-sm gap-1">
                <.icon name="hero-magnifying-glass-micro" class="size-4" /> RAG Query
              </button>
            </div>
          </header>

          <div class="flex-1 overflow-y-auto p-4">
            <div
              :if={!@rag_enabled}
              class="alert alert-warning mb-4 flex items-start gap-3"
            >
              <.icon name="hero-exclamation-triangle-micro" class="size-6 mt-0.5 flex-shrink-0" />
              <div>
                <h3 class="font-bold text-lg">RAG Ingest Disabled</h3>
                <p class="text-sm mt-1">
                  No embedding model is configured. Data sources can be managed but
                  documents will not be embedded for semantic search. An admin can
                  configure an embedding model in <.link
                    navigate={~p"/admin/rag"}
                    class="link link-primary font-medium"
                  >Admin &rarr; RAG</.link>.
                </p>
              </div>
            </div>
            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
              <SourcesComponents.source_card
                :for={source <- @data_sources}
                source={source}
                current_user={@current_user}
              />
              <SourcesComponents.add_source_card />
            </div>
          </div>

          <SourcesComponents.rag_query_modal
            show={@show_rag_query}
            collections={@rag_query_collections}
            results={@rag_query_results}
            loading={@rag_query_loading}
            error={@rag_query_error}
          />

          <SourcesComponents.configure_source_modal
            :if={@configure_source}
            show={@show_configure_source}
            source={@configure_source}
            config_fields={@configure_source_fields}
            config_form={@configure_source_form}
          />

          <SourcesComponents.add_source_modal
            show={@show_add_source}
            source_types={@available_source_types}
          />

          <ChatComponents.confirm_modal
            show={@confirm_delete_source_id != nil}
            title="Delete data source"
            message="Are you sure? This will permanently delete the data source and all its documents."
            confirm_event="delete_source"
            cancel_event="cancel_delete_source"
          />
        <% end %>
        <%= if @live_action == :source_show && @current_source do %>
          <%!-- Source Documents --%>
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
                <.link navigate={~p"/sources"} class="btn btn-ghost btn-xs">
                  <.icon name="hero-arrow-left-micro" class="size-4" />
                </.link>
                <h1 class="text-lg font-semibold">{@current_source.name}</h1>
                <span
                  :if={Map.get(@current_source, :builtin, false)}
                  class="badge badge-sm badge-primary"
                >
                  built-in
                </span>
              </div>
              <div class="flex items-center gap-2">
                <button
                  phx-click="queue_index_source"
                  class="btn btn-sm btn-outline gap-1"
                  title="Queue RAG indexing for all documents"
                >
                  <.icon name="hero-queue-list-micro" class="size-4" /> Queue Index
                </button>
              </div>
              <div
                :if={!Map.get(@current_source, :builtin, false)}
                class="flex items-center gap-2"
              >
                <span
                  :if={@current_source.sync_status == "syncing"}
                  class="badge badge-sm badge-info gap-1"
                >
                  <span class="loading loading-spinner loading-xs"></span> syncing
                </span>
                <span
                  :if={@current_source.sync_status == "complete"}
                  class="badge badge-sm badge-success"
                >
                  synced
                </span>
                <span
                  :if={@current_source.sync_status == "error"}
                  class="badge badge-sm badge-error"
                  title={@current_source.last_sync_error}
                >
                  error
                </span>
                <span
                  :if={@current_source.last_synced_at}
                  class="text-xs text-base-content/50"
                >
                  {Calendar.strftime(@current_source.last_synced_at, "%b %d, %H:%M")}
                </span>
                <button
                  phx-click="sync_source"
                  class="btn btn-primary btn-sm gap-1"
                  disabled={@current_source.sync_status == "syncing"}
                >
                  <.icon name="hero-arrow-path-micro" class="size-4" /> Sync
                </button>
                <button
                  phx-click="open_sharing"
                  phx-value-entity-type="source"
                  phx-value-entity-id={@current_source.id}
                  class="btn btn-ghost btn-sm btn-square"
                  title="Share"
                >
                  <.icon name="hero-share-micro" class="size-4" />
                </button>
              </div>
            </div>
          </header>

          <div class="flex-1 overflow-y-auto p-4 max-w-3xl mx-auto w-full">
            <WikiComponents.document_list
              source={@current_source}
              result={@source_documents}
              search={@source_search}
            />
          </div>

          <SharingComponents.sharing_modal
            show={@show_sharing}
            entity_type={@sharing_entity_type}
            entity_id={@sharing_entity_id}
            acls={@sharing_acls}
            user_search_results={@sharing_user_search_results}
            user_search_query={@sharing_user_search_query}
            groups={@sharing_groups}
            error={@sharing_error}
            current_user_id={@current_user.id}
          />
        <% end %>
        <%= if @live_action == :source_document_show && @source_document do %>
          <%!-- Document RAG Detail --%>
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
                <.link
                  navigate={~p"/sources/#{SourcesComponents.source_url_id(@current_source)}"}
                  class="btn btn-ghost btn-xs"
                >
                  <.icon name="hero-arrow-left-micro" class="size-4" />
                </.link>
                <h1 class="text-lg font-semibold truncate">{@source_document.title}</h1>
              </div>
              <.link
                navigate={document_go_url(@current_source, @source_document)}
                class="btn btn-primary btn-sm gap-1"
              >
                <.icon name="hero-arrow-top-right-on-square-micro" class="size-4" /> Go
              </.link>
            </div>
          </header>

          <div class="flex-1 overflow-y-auto p-4 max-w-3xl mx-auto w-full space-y-6">
            <%!-- Stats Card --%>
            <div class="card bg-base-200/50 border border-base-300">
              <div class="card-body p-4 space-y-3">
                <h3 class="font-semibold text-sm">RAG Index</h3>
                <%= if @rag_document do %>
                  <div class="grid grid-cols-2 sm:grid-cols-4 gap-3">
                    <div>
                      <p class="text-xs text-base-content/50">Status</p>
                      <span class={[
                        "badge badge-sm",
                        case @rag_document.status do
                          "embedded" -> "badge-success"
                          "error" -> "badge-error"
                          _ -> "badge-warning"
                        end
                      ]}>
                        {@rag_document.status}
                      </span>
                    </div>
                    <div>
                      <p class="text-xs text-base-content/50">Chunks</p>
                      <p class="font-mono text-sm">{length(@rag_chunks)}</p>
                    </div>
                    <div>
                      <p class="text-xs text-base-content/50">Total Tokens</p>
                      <p class="font-mono text-sm">
                        {Enum.sum(Enum.map(@rag_chunks, fn c -> c.token_count || 0 end))}
                      </p>
                    </div>
                    <div>
                      <p class="text-xs text-base-content/50">Document Hash</p>
                      <p class="font-mono text-xs truncate" title={@rag_document.content_hash}>
                        {truncate_hash(@rag_document.content_hash)}
                      </p>
                    </div>
                  </div>
                  <div
                    :if={@rag_document.status == "error" && @rag_document.error_message}
                    class="mt-2 p-2 bg-error/10 border border-error/20 rounded-lg"
                  >
                    <p class="text-xs text-error font-medium">
                      {@rag_document.error_message}
                    </p>
                  </div>
                <% else %>
                  <p class="text-sm text-base-content/50">
                    Not indexed. This document has no RAG data yet.
                  </p>
                <% end %>
              </div>
            </div>

            <%!-- Chunks --%>
            <%= if @rag_chunks != [] do %>
              <div class="space-y-3">
                <h3 class="font-semibold text-sm">
                  Chunks ({length(@rag_chunks)})
                </h3>
                <div
                  :for={chunk <- @rag_chunks}
                  class="card bg-base-100 border border-base-300 overflow-hidden"
                >
                  <div class="flex items-center justify-between px-3 py-2 bg-base-200/50 text-xs">
                    <div class="flex items-center gap-3">
                      <span class="badge badge-sm badge-primary font-mono">
                        #{chunk.position}
                      </span>
                      <span :if={chunk.token_count} class="text-base-content/60">
                        {chunk.token_count} tokens
                      </span>
                    </div>
                    <span
                      :if={chunk.content_hash}
                      class="font-mono text-base-content/40"
                      title={chunk.content_hash}
                    >
                      {truncate_hash(chunk.content_hash)}
                    </span>
                  </div>
                  <div class="px-3 py-2">
                    <pre class="text-xs text-base-content/80 whitespace-pre-wrap font-mono leading-relaxed max-h-48 overflow-y-auto">{chunk.content}</pre>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </main>
    </div>
    """
  end

  # --- Event Handlers ---

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, sidebar_open: !socket.assigns.sidebar_open)}
  end

  @impl true
  def handle_event("select_conversation", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: "/c/#{id}")}
  end

  @sharing_events SharingLive.sharing_events()

  @impl true
  def handle_event(event, params, socket) when event in @sharing_events do
    SharingLive.handle_event(event, params, socket)
  end

  @impl true
  def handle_event("source_search", %{"search" => search}, socket) do
    user_id = socket.assigns.current_user.id
    source_ref = socket.assigns.current_source.id

    result =
      Liteskill.DataSources.list_documents_paginated(source_ref, user_id,
        page: 1,
        search: if(search == "", do: nil, else: search)
      )

    {:noreply, assign(socket, source_search: search, source_documents: result)}
  end

  @impl true
  def handle_event("source_page", %{"page" => page}, socket) do
    user_id = socket.assigns.current_user.id
    source_ref = socket.assigns.current_source.id
    search = socket.assigns.source_search

    result =
      Liteskill.DataSources.list_documents_paginated(source_ref, user_id,
        page: safe_page(page),
        search: if(search == "", do: nil, else: search)
      )

    {:noreply, assign(socket, source_documents: result)}
  end

  # --- RAG Query Events ---

  @impl true
  def handle_event("open_rag_query", _params, socket) do
    {:noreply,
     assign(socket,
       show_rag_query: true,
       rag_query_results: [],
       rag_query_error: nil,
       rag_query_loading: false
     )}
  end

  @impl true
  def handle_event("close_rag_query", _params, socket) do
    {:noreply,
     assign(socket,
       show_rag_query: false,
       rag_query_results: [],
       rag_query_error: nil,
       rag_query_loading: false
     )}
  end

  @impl true
  def handle_event("open_configure_source", %{"source-id" => source_id}, socket) do
    user_id = socket.assigns.current_user.id

    case Liteskill.DataSources.get_source(source_id, user_id) do
      {:ok, source} ->
        fields = Liteskill.DataSources.config_fields_for(source.source_type)

        # Pre-fill form with existing metadata (skip password fields for security)
        prefill =
          Map.filter(source.metadata || %{}, fn {k, _v} ->
            field = Enum.find(fields, &(&1.key == k))
            field != nil && field.type != :password
          end)

        {:noreply,
         assign(socket,
           show_configure_source: true,
           configure_source: source,
           configure_source_fields: fields,
           configure_source_form: to_form(prefill, as: :config)
         )}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close_configure_source", _params, socket) do
    {:noreply,
     assign(socket,
       show_configure_source: false,
       configure_source: nil,
       configure_source_fields: [],
       configure_source_form: to_form(%{}, as: :config)
     )}
  end

  @impl true
  def handle_event("save_source_config", %{"source_id" => source_id, "config" => config_params}, socket) do
    user_id = socket.assigns.current_user.id

    metadata =
      config_params
      |> Enum.reject(fn {_k, v} -> v == "" end)
      |> Map.new()

    result =
      if metadata == %{} do
        {:ok, :noop}
      else
        Liteskill.DataSources.update_source(source_id, %{metadata: metadata}, user_id)
      end

    case result do
      {:ok, updated} when not is_atom(updated) ->
        maybe_populate_description(updated, user_id)
        sources = Liteskill.DataSources.list_sources_with_counts(user_id)

        {:noreply,
         assign(socket,
           show_configure_source: false,
           configure_source: nil,
           configure_source_fields: [],
           configure_source_form: to_form(%{}, as: :config),
           data_sources: sources
         )}

      {:ok, _} ->
        sources = Liteskill.DataSources.list_sources_with_counts(user_id)

        {:noreply,
         assign(socket,
           show_configure_source: false,
           configure_source: nil,
           configure_source_fields: [],
           configure_source_form: to_form(%{}, as: :config),
           data_sources: sources
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("save source configuration", reason))}
    end
  end

  @impl true
  def handle_event("open_add_source", _params, socket) do
    {:noreply, assign(socket, show_add_source: true)}
  end

  @impl true
  def handle_event("close_add_source", _params, socket) do
    {:noreply, assign(socket, show_add_source: false)}
  end

  @impl true
  def handle_event("add_source", %{"source-type" => source_type, "name" => name}, socket) do
    user_id = socket.assigns.current_user.id

    case Liteskill.DataSources.create_source(
           %{name: name, source_type: source_type, description: ""},
           user_id
         ) do
      {:ok, new_source} ->
        fields = Liteskill.DataSources.config_fields_for(source_type)
        sources = Liteskill.DataSources.list_sources_with_counts(user_id)

        {:noreply,
         assign(socket,
           show_add_source: false,
           data_sources: sources,
           show_configure_source: true,
           configure_source: new_source,
           configure_source_fields: fields,
           configure_source_form: to_form(%{}, as: :config)
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("add data source", reason))}
    end
  end

  @impl true
  def handle_event("confirm_delete_source", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirm_delete_source_id: id)}
  end

  @impl true
  def handle_event("cancel_delete_source", _params, socket) do
    {:noreply, assign(socket, confirm_delete_source_id: nil)}
  end

  @impl true
  def handle_event("delete_source", _params, socket) do
    user = socket.assigns.current_user
    id = socket.assigns.confirm_delete_source_id

    case Liteskill.DataSources.delete_source(id, user.id) do
      {:ok, _} ->
        sources = Liteskill.DataSources.list_sources_with_counts(user.id)

        {:noreply,
         socket
         |> assign(data_sources: sources, confirm_delete_source_id: nil)
         |> put_flash(:info, "Data source deleted.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(confirm_delete_source_id: nil)
         |> put_flash(:error, action_error("delete data source", reason))}
    end
  end

  @impl true
  def handle_event("sync_source", _params, socket) do
    source = socket.assigns.current_source
    user_id = socket.assigns.current_user.id

    case Liteskill.DataSources.start_sync(source.id, user_id) do
      :ok ->
        case Liteskill.DataSources.get_source(source.id, user_id) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> assign(current_source: updated)
             |> put_flash(:info, "Sync started.")}

          {:error, _} ->
            {:noreply, put_flash(socket, :info, "Sync started.")}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("start sync", reason))}
    end
  end

  @impl true
  def handle_event("queue_index_source", _params, socket) do
    source = socket.assigns.current_source
    user_id = socket.assigns.current_user.id

    case Liteskill.DataSources.enqueue_index_source(source.id, user_id) do
      {:ok, 0} ->
        {:noreply, put_flash(socket, :info, "No documents with content to index.")}

      {:ok, count} ->
        {:noreply, put_flash(socket, :info, "Queued indexing for #{count} documents.")}
    end
  end

  @impl true
  def handle_event("rag_search", %{"collection_id" => coll_id, "query" => query}, socket) do
    query = String.trim(query)

    if query == "" do
      {:noreply, assign(socket, rag_query_error: "Please enter a search query")}
    else
      user_id = socket.assigns.current_user.id
      lv = self()

      Task.Supervisor.start_child(Liteskill.TaskSupervisor, fn ->
        result =
          try do
            if coll_id == "all" do
              Liteskill.Rag.augment_context(query, user_id)
            else
              Liteskill.Rag.search_accessible(coll_id, query, user_id,
                top_n: 10,
                search_limit: 50
              )
            end
          rescue
            e in [
              Postgrex.Error,
              DBConnection.ConnectionError,
              Ecto.QueryError,
              RuntimeError,
              ArgumentError
            ] ->
              {:error, Exception.message(e)}
          end

        send(lv, {:rag_search_result, result})
      end)

      {:noreply, assign(socket, rag_query_loading: true, rag_query_results: [], rag_query_error: nil)}
    end
  end

  # --- handle_info callbacks ---

  @impl true
  def handle_info({:rag_search_result, {:ok, results}}, socket) do
    enriched = Liteskill.Rag.preload_result_sources(results)

    {:noreply, assign(socket, rag_query_loading: false, rag_query_results: enriched)}
  end

  @impl true
  def handle_info({:rag_search_result, {:error, reason}}, socket) do
    message =
      case reason do
        %{status: status} -> "Search failed (HTTP #{status})"
        _ -> "Search failed"
      end

    {:noreply, assign(socket, rag_query_loading: false, rag_query_results: [], rag_query_error: message)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Helpers ---

  defp source_id_from_url("builtin-" <> rest), do: "builtin:" <> rest
  defp source_id_from_url(id), do: id

  defp document_go_url(%{id: "builtin:wiki"}, doc), do: ~p"/wiki/#{doc.id}"

  defp document_go_url(_source, doc) do
    case doc.metadata do
      %{"url" => url} when is_binary(url) and url != "" -> url
      _ -> "#"
    end
  end

  defp truncate_hash(nil), do: "-"
  defp truncate_hash(hash) when byte_size(hash) > 12, do: String.slice(hash, 0, 12) <> "..."
  defp truncate_hash(hash), do: hash

  defp maybe_populate_description(source, user_id) do
    case source.source_type do
      "google_drive" ->
        alias Liteskill.DataSources.Connectors.GoogleDrive

        case GoogleDrive.describe_folder(source, []) do
          {:ok, description} ->
            Liteskill.DataSources.update_source(source.id, %{description: description}, user_id)

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp safe_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {n, _} when n > 0 -> n
      _ -> 1
    end
  end

  defp safe_page(page) when is_integer(page) and page > 0, do: page
  defp safe_page(_), do: 1
end
