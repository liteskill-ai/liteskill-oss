defmodule LiteskillWeb.ChatLive do
  use LiteskillWeb, :live_view

  import LiteskillWeb.FormatHelpers, only: [format_cost: 1, format_number: 1]

  alias Liteskill.Chat
  alias Liteskill.Chat.{MessageBuilder, ToolCall}
  alias Liteskill.LLM.StreamHandler
  alias Liteskill.McpServers
  alias Liteskill.McpServers.Client, as: McpClient
  alias Liteskill.Repo
  alias LiteskillWeb.ChatComponents
  alias LiteskillWeb.McpComponents
  alias LiteskillWeb.AdminLive
  alias LiteskillWeb.ProfileLive
  alias LiteskillWeb.SettingsLive
  alias LiteskillWeb.{PipelineComponents, PipelineLive}
  alias LiteskillWeb.{ReportComponents, ReportsLive}
  alias LiteskillWeb.{AgentStudioComponents, AgentStudioLive}
  alias LiteskillWeb.{SharingComponents, SharingLive, SourcesComponents, WikiComponents}

  @impl true
  def mount(_params, _session, socket) do
    conversations = Chat.list_conversations(socket.assigns.current_user.id)

    user = socket.assigns.current_user

    available_llm_models =
      Liteskill.LlmModels.list_active_models(user.id, model_type: "inference")

    preferred_id = get_in(user.preferences, ["preferred_llm_model_id"])
    selected_server_ids = McpServers.load_selected_server_ids(user.id)
    auto_confirm_tools = get_in(user.preferences, ["auto_confirm_tools"]) != false

    selected_llm_model_id =
      cond do
        preferred_id && Enum.any?(available_llm_models, &(&1.id == preferred_id)) ->
          preferred_id

        available_llm_models != [] ->
          hd(available_llm_models).id

        true ->
          nil
      end

    {:ok,
     socket
     |> assign(
       conversations: conversations,
       conversation: nil,
       messages: [],
       form: to_form(%{"content" => ""}, as: :message),
       streaming: false,
       stream_content: "",
       mcp_servers: [],
       show_mcp_modal: false,
       mcp_form:
         to_form(
           %{
             "name" => "",
             "url" => "",
             "api_key" => "",
             "description" => "",
             "headers" => "",
             "global" => false
           },
           as: :mcp_server
         ),
       editing_mcp: nil,
       # Tool picker state
       available_tools: [],
       selected_server_ids: selected_server_ids,
       show_tool_picker: false,
       auto_confirm_tools: auto_confirm_tools,
       pending_tool_calls: [],
       tool_call_modal: nil,
       tools_loading: false,
       stream_task_pid: nil,
       inspecting_server: nil,
       inspecting_tools: [],
       inspecting_tools_loading: false,
       sidebar_open: true,
       confirm_delete_id: nil,
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
       show_sources_sidebar: false,
       sidebar_sources: [],
       show_source_modal: false,
       source_modal_data: %{},
       show_raw_output_modal: false,
       raw_output_message_id: nil,
       raw_output_content: "",
       stream_error: nil,
       # Source configuration modal
       show_configure_source: false,
       configure_source: nil,
       configure_source_fields: [],
       configure_source_form: to_form(%{}, as: :config),
       # Add source modal
       show_add_source: false,
       available_source_types: Liteskill.DataSources.available_source_types(),
       # Edit message state
       editing_message_id: nil,
       editing_message_content: "",
       edit_selected_server_ids: MapSet.new(),
       edit_show_tool_picker: false,
       edit_auto_confirm_tools: true,
       # Conversations management view
       managed_conversations: [],
       conversations_page: 1,
       conversations_search: "",
       conversations_total: 0,
       conversations_selected: MapSet.new(),
       conversations_page_size: 20,
       confirm_bulk_delete: false,
       # Sharing modal state
       show_sharing: false,
       sharing_entity_type: nil,
       sharing_entity_id: nil,
       sharing_acls: [],
       sharing_user_search_results: [],
       sharing_user_search_query: "",
       sharing_groups: [],
       sharing_error: nil,
       # LLM model selection
       available_llm_models: available_llm_models,
       selected_llm_model_id: selected_llm_model_id,
       # Cost guardrail
       cost_limit: nil,
       cost_limit_input: "",
       cost_limit_tokens: nil,
       show_cost_popover: false,
       # Conversation usage modal
       show_usage_modal: false,
       usage_modal_data: nil,
       has_admin_access: Liteskill.Rbac.has_any_admin_permission?(user.id),
       single_user_mode: Liteskill.SingleUser.enabled?(),
       settings_mode: false
     )
     |> assign(ReportsLive.reports_assigns())
     |> assign(PipelineLive.pipeline_assigns())
     |> assign(AgentStudioLive.studio_assigns())
     |> assign(AdminLive.admin_assigns())
     |> assign(ProfileLive.profile_assigns())
     |> then(fn socket ->
       if MapSet.size(selected_server_ids) > 0, do: send(self(), :fetch_tools)
       socket
     end), layout: {LiteskillWeb.Layouts, :chat}}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if socket.assigns.current_user.force_password_change &&
         socket.assigns.live_action != :password do
      {:noreply, push_navigate(socket, to: ~p"/profile/password")}
    else
      {:noreply,
       socket
       |> assign(show_raw_output_modal: false, raw_output_message_id: nil, raw_output_content: "")
       |> push_event("nav", %{})
       |> push_accent_color()
       |> apply_action(socket.assigns.live_action, params)}
    end
  end

  defp push_accent_color(socket) do
    color = Liteskill.Accounts.User.accent_color(socket.assigns.current_user)
    push_event(socket, "set-accent", %{color: color})
  end

  defp apply_action(socket, action, _params)
       when action in [:info, :password, :user_providers, :user_models] do
    maybe_unsubscribe(socket)

    socket
    |> assign(
      conversation: nil,
      messages: [],
      streaming: false,
      stream_content: "",
      pending_tool_calls: [],
      settings_mode: false
    )
    |> ProfileLive.apply_profile_action(action, socket.assigns.current_user)
  end

  defp apply_action(socket, action, _params)
       when action in [
              :admin_usage,
              :admin_servers,
              :admin_users,
              :admin_groups,
              :admin_providers,
              :admin_models,
              :admin_roles,
              :admin_rag,
              :admin_setup
            ] do
    maybe_unsubscribe(socket)

    socket
    |> assign(
      conversation: nil,
      messages: [],
      streaming: false,
      stream_content: "",
      pending_tool_calls: [],
      settings_mode: false
    )
    |> AdminLive.apply_admin_action(action, socket.assigns.current_user)
  end

  defp apply_action(socket, action, _params)
       when action in [
              :settings_usage,
              :settings_general,
              :settings_providers,
              :settings_models,
              :settings_rag,
              :settings_account
            ] do
    maybe_unsubscribe(socket)
    user = socket.assigns.current_user

    socket =
      socket
      |> assign(
        conversation: nil,
        messages: [],
        streaming: false,
        stream_content: "",
        pending_tool_calls: [],
        settings_mode: true
      )

    case action do
      :settings_account ->
        ProfileLive.apply_profile_action(socket, :info, user)

      _ ->
        admin_action = SettingsLive.settings_to_admin_action(action)
        AdminLive.apply_admin_action(socket, admin_action, user)
    end
  end

  defp apply_action(socket, :index, _params) do
    # Unsubscribe from previous conversation if any
    maybe_unsubscribe(socket)

    socket
    |> assign(
      conversation: nil,
      messages: [],
      streaming: false,
      stream_content: "",
      pending_tool_calls: [],
      page_title: "Liteskill"
    )
  end

  defp apply_action(socket, :conversations, _params) do
    maybe_unsubscribe(socket)
    user_id = socket.assigns.current_user.id
    page_size = socket.assigns.conversations_page_size

    managed = Chat.list_conversations(user_id, limit: page_size, offset: 0)
    total = Chat.count_conversations(user_id)

    socket
    |> assign(
      conversation: nil,
      messages: [],
      streaming: false,
      stream_content: "",
      pending_tool_calls: [],
      managed_conversations: managed,
      conversations_page: 1,
      conversations_search: "",
      conversations_total: total,
      conversations_selected: MapSet.new(),
      confirm_bulk_delete: false,
      page_title: "Conversations"
    )
  end

  defp apply_action(socket, :mcp_servers, _params) do
    maybe_unsubscribe(socket)
    user_id = socket.assigns.current_user.id
    servers = McpServers.list_servers(user_id)

    socket
    |> assign(
      conversation: nil,
      messages: [],
      streaming: false,
      stream_content: "",
      mcp_servers: servers,
      show_mcp_modal: false,
      editing_mcp: nil,
      pending_tool_calls: [],
      page_title: "Tools"
    )
  end

  defp apply_action(socket, :pipeline, params) do
    maybe_unsubscribe(socket)
    PipelineLive.apply_pipeline_action(socket, :pipeline, params)
  end

  defp apply_action(socket, :sources, _params) do
    maybe_unsubscribe(socket)
    user_id = socket.assigns.current_user.id
    sources = Liteskill.DataSources.list_sources_with_counts(user_id)

    rag_collections = Liteskill.Rag.list_accessible_collections(user_id)

    socket
    |> assign(
      conversation: nil,
      messages: [],
      streaming: false,
      stream_content: "",
      pending_tool_calls: [],
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
    maybe_unsubscribe(socket)
    user_id = socket.assigns.current_user.id
    source_id = source_id_from_url(source_url_id)

    case Liteskill.DataSources.get_source(source_id, user_id) do
      {:ok, source} ->
        source_ref = source.id
        search = socket.assigns.source_search

        result =
          Liteskill.DataSources.list_documents_paginated(source_ref, user_id,
            page: 1,
            search: if(search == "", do: nil, else: search)
          )

        socket
        |> assign(
          conversation: nil,
          messages: [],
          streaming: false,
          stream_content: "",
          pending_tool_calls: [],
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

  defp apply_action(
         socket,
         :source_document_show,
         %{"source_id" => source_url_id, "document_id" => doc_id}
       ) do
    maybe_unsubscribe(socket)
    user_id = socket.assigns.current_user.id
    source_id = source_id_from_url(source_url_id)

    with {:ok, source} <- Liteskill.DataSources.get_source(source_id, user_id),
         {:ok, doc} <- Liteskill.DataSources.get_document(doc_id, user_id) do
      {rag_doc, chunks} =
        case Liteskill.Rag.get_rag_document_for_source_doc(doc_id, user_id) do
          {:ok, rd} -> {rd, Liteskill.Rag.list_chunks_for_document(rd.id, user_id)}
          {:error, _} -> {nil, []}
        end

      socket
      |> assign(
        conversation: nil,
        messages: [],
        streaming: false,
        stream_content: "",
        pending_tool_calls: [],
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

  defp apply_action(socket, action, params) when action in [:reports, :report_show] do
    maybe_unsubscribe(socket)
    ReportsLive.apply_reports_action(socket, action, params)
  end

  @studio_actions AgentStudioLive.studio_actions()

  defp apply_action(socket, action, params) when action in @studio_actions do
    maybe_unsubscribe(socket)
    AgentStudioLive.apply_studio_action(socket, action, params)
  end

  defp apply_action(socket, :show, params) do
    conversation_id = params["conversation_id"]
    auto_stream = params["auto_stream"] == "1"
    user_id = socket.assigns.current_user.id

    # Unsubscribe from previous conversation
    maybe_unsubscribe(socket)

    case Chat.get_conversation(conversation_id, user_id) do
      {:ok, conversation} ->
        # Subscribe to PubSub for real-time updates
        topic = "event_store:#{conversation.stream_id}"
        Phoenix.PubSub.subscribe(Liteskill.PubSub, topic)

        # If conversation is stuck in streaming but we have no active task, recover it
        {conversation, streaming} =
          if conversation.status == "streaming" && socket.assigns.stream_task_pid == nil do
            Chat.recover_stream(conversation_id, user_id)
            _ = :sys.get_state(Liteskill.Chat.Projector)
            {:ok, recovered} = Chat.get_conversation(conversation_id, user_id)
            {recovered, false}
          else
            {conversation, conversation.status == "streaming"}
          end

        pending = if streaming, do: load_pending_tool_calls(conversation.messages), else: []

        socket =
          socket
          |> assign(
            conversation: conversation,
            messages: conversation.messages,
            streaming: streaming,
            stream_content: "",
            pending_tool_calls: pending,
            page_title: conversation.title
          )

        # Auto-start stream after navigation from new conversation creation
        if auto_stream && !streaming do
          last_user_msg =
            conversation.messages
            |> Enum.filter(&(&1.role == "user"))
            |> List.last()

          tool_config = if last_user_msg, do: last_user_msg.tool_config
          pid = trigger_llm_stream(conversation, user_id, socket, tool_config)

          assign(socket,
            streaming: true,
            stream_content: "",
            stream_error: nil,
            pending_tool_calls: [],
            stream_task_pid: pid
          )
        else
          socket
        end

      {:error, reason} ->
        socket
        |> put_flash(:error, action_error("load conversation", reason))
        |> push_navigate(to: ~p"/")
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:show_raw_output_modal, fn -> false end)
      |> assign_new(:raw_output_message_id, fn -> nil end)
      |> assign_new(:raw_output_content, fn -> "" end)

    ~H"""
    <div class="flex h-screen relative">
      <Layouts.sidebar
        sidebar_open={@sidebar_open}
        live_action={@live_action}
        conversations={@conversations}
        active_conversation_id={@conversation && @conversation.id}
        current_user={@current_user}
        has_admin_access={@has_admin_access}
        single_user_mode={@single_user_mode}
      />

      <%!-- Main Area --%>
      <main class="flex-1 flex flex-col min-w-0">
        <%= if @live_action == :pipeline do %>
          <PipelineComponents.pipeline_dashboard
            stats={@pipeline_stats}
            rates={@pipeline_rates}
            chart_data={@pipeline_chart_data}
            jobs={@pipeline_jobs}
            job_search={@pipeline_job_search}
            scope={@pipeline_scope}
            is_admin={@pipeline_is_admin}
            window={@pipeline_window}
          />
        <% end %>
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
        <%= if @live_action == :mcp_servers do %>
          <%!-- MCP Servers --%>
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
                <h1 class="text-lg font-semibold">Tools</h1>
              </div>
              <button phx-click="show_add_mcp" class="btn btn-primary btn-sm gap-1">
                <.icon name="hero-plus-micro" class="size-4" /> Add Server
              </button>
            </div>
          </header>

          <div class="flex-1 overflow-y-auto p-4">
            <div
              :if={@mcp_servers != []}
              class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4"
            >
              <McpComponents.mcp_server_card
                :for={server <- @mcp_servers}
                server={server}
                owned={server.user_id == @current_user.id}
              />
            </div>
            <p
              :if={@mcp_servers == []}
              class="text-base-content/50 text-center py-12"
            >
              No tool servers configured yet. Click "Add Server" to get started.
            </p>
          </div>

          <ChatComponents.modal
            id="mcp-modal"
            title={if @editing_mcp, do: "Edit Server", else: "Add Server"}
            show={@show_mcp_modal}
            on_close="close_mcp_modal"
          >
            <.form for={@mcp_form} phx-submit="save_mcp" class="space-y-4">
              <input :if={@editing_mcp} type="hidden" name="mcp_server[id]" value={@editing_mcp.id} />

              <div
                :if={match?(%Ecto.Changeset{action: a} when a != nil, @mcp_form.source)}
                class="alert alert-error text-sm"
              >
                <.icon name="hero-exclamation-circle" class="size-5 shrink-0" />
                <div>
                  <p class="font-semibold">Could not save server:</p>
                  <ul class="list-disc list-inside mt-1">
                    <li :for={
                      {field, msgs} <-
                        Ecto.Changeset.traverse_errors(@mcp_form.source, fn {msg, opts} ->
                          Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
                            opts
                            |> Keyword.get(String.to_existing_atom(key), key)
                            |> to_string()
                          end)
                        end)
                    }>
                      <span class="font-medium">{Phoenix.Naming.humanize(field)}:</span>
                      {Enum.join(msgs, ", ")}
                    </li>
                  </ul>
                </div>
              </div>

              <.input
                field={@mcp_form[:name]}
                label="Name *"
                type="text"
                class="input input-bordered w-full"
                required
              />
              <.input
                field={@mcp_form[:url]}
                label="URL *"
                type="url"
                class="input input-bordered w-full"
                required
              />
              <.input
                field={@mcp_form[:api_key]}
                label="API Key"
                type="password"
                class="input input-bordered w-full"
                autocomplete="off"
              />
              <.input
                field={@mcp_form[:description]}
                label="Description"
                type="textarea"
                class="textarea textarea-bordered w-full"
                rows={2}
              />
              <div class="fieldset mb-2">
                <label>
                  <span class="label mb-1">Custom Headers (JSON)</span>
                  <textarea
                    name={@mcp_form[:headers].name}
                    class="textarea textarea-bordered w-full font-mono text-xs"
                    rows="3"
                    placeholder="{}"
                  >{mcp_headers_value(@mcp_form[:headers].value)}</textarea>
                </label>
              </div>
              <.input
                field={@mcp_form[:global]}
                label="Share globally with all users"
                type="checkbox"
              />
              <div class="flex justify-end gap-2 pt-2">
                <button type="button" phx-click="close_mcp_modal" class="btn btn-ghost btn-sm">
                  Cancel
                </button>
                <button type="submit" class="btn btn-primary btn-sm">
                  {if @editing_mcp, do: "Update", else: "Create"}
                </button>
              </div>
            </.form>
          </ChatComponents.modal>
        <% end %>
        <%= if @live_action == :reports do %>
          <%!-- Reports --%>
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
                  Reports
                </h1>
              </div>
            </div>
          </header>

          <div class="flex-1 overflow-y-auto">
            <div :if={@reports != []} class="divide-y divide-base-200">
              <ReportComponents.report_row
                :for={report <- @reports}
                report={report}
                owned={report.user_id == @current_user.id}
              />
            </div>
            <ReportComponents.reports_pagination
              page={@reports_page}
              total_pages={@reports_total_pages}
            />
            <p
              :if={@reports == []}
              class="text-base-content/50 text-center py-12"
            >
              No reports yet. Use the Reports tools in a conversation to create one.
            </p>
          </div>
        <% end %>
        <%= if @live_action == :report_show do %>
          <%!-- Report Detail --%>
          <header
            id="report-detail"
            phx-hook="DownloadMarkdown"
            class="px-4 py-3 border-b border-base-300 flex-shrink-0"
          >
            <div class="flex flex-wrap items-center justify-between gap-2">
              <div class="flex items-center gap-2 min-w-0">
                <button
                  :if={!@sidebar_open}
                  phx-click="toggle_sidebar"
                  class="btn btn-circle btn-ghost btn-sm"
                >
                  <.icon name="hero-bars-3-micro" class="size-5" />
                </button>
                <.link navigate={~p"/reports"} class="btn btn-ghost btn-sm btn-circle">
                  <.icon name="hero-arrow-left-micro" class="size-5" />
                </.link>
                <h1
                  class="text-xl tracking-wide truncate"
                  style="font-family: 'Bebas Neue', sans-serif;"
                >
                  {@report && @report.title}
                </h1>
              </div>
              <div class="flex flex-wrap gap-1">
                <%= if @report_mode == :view do %>
                  <button phx-click="report_edit_mode" class="btn btn-ghost btn-sm gap-1">
                    <.icon name="hero-pencil-square-micro" class="size-4" /> Edit
                  </button>
                <% else %>
                  <button phx-click="address_comments" class="btn btn-primary btn-sm gap-1">
                    <.icon name="hero-chat-bubble-left-right-micro" class="size-4" /> Address Comments
                  </button>
                  <button phx-click="report_view_mode" class="btn btn-ghost btn-sm gap-1">
                    <.icon name="hero-eye-micro" class="size-4" /> View
                  </button>
                <% end %>
                <button phx-click="export_report" class="btn btn-ghost btn-sm gap-1">
                  <.icon name="hero-arrow-down-tray-micro" class="size-4" /> Export
                </button>
                <button phx-click="open_wiki_export_modal" class="btn btn-ghost btn-sm gap-1">
                  <.icon name="hero-book-open-micro" class="size-4" /> Export to Wiki
                </button>
                <button
                  :if={@report}
                  phx-click="open_sharing"
                  phx-value-entity-type="report"
                  phx-value-entity-id={@report.id}
                  class="btn btn-ghost btn-sm gap-1"
                  title="Share"
                >
                  <.icon name="hero-share-micro" class="size-4" /> Share
                </button>
              </div>
            </div>
          </header>

          <div class="flex-1 overflow-y-auto px-6 py-6 space-y-6">
            <%= if @report_mode == :view do %>
              <%!-- View mode: clean markdown rendering --%>
              <div
                :if={@report_markdown != ""}
                id="report-markdown"
                phx-hook="CopyCode"
                class="prose prose-sm max-w-none"
              >
                {LiteskillWeb.Markdown.render(@report_markdown)}
              </div>
              <p
                :if={@report_markdown == ""}
                class="text-base-content/50 text-center py-12"
              >
                This report has no content yet. Use the Reports tools in a conversation to add content.
              </p>
            <% else %>
              <%!-- Edit mode: section tree with comments and inline editing --%>
              <div :if={@report_comments != []} class="space-y-2">
                <h3 class="text-sm font-semibold text-base-content/70">Report Comments</h3>
                <ReportComponents.section_comment :for={c <- @report_comments} comment={c} />
              </div>

              <form phx-submit="add_report_comment" class="flex gap-2">
                <input
                  type="text"
                  name="body"
                  placeholder="Add a report comment..."
                  class="input input-bordered input-sm flex-1"
                />
                <button type="submit" class="btn btn-sm btn-ghost">Comment</button>
              </form>

              <div :if={@section_tree != []} class="space-y-4">
                <ReportComponents.section_node
                  :for={node <- @section_tree}
                  node={node}
                  depth={1}
                  editing_section_id={@editing_section_id}
                />
              </div>

              <p
                :if={@section_tree == [] && @report_comments == []}
                class="text-base-content/50 text-center py-12"
              >
                This report has no sections yet. Use the Reports tools in a conversation to add content.
              </p>
            <% end %>
          </div>

          <ChatComponents.modal
            id="wiki-export-modal"
            title="Export to Wiki"
            show={@show_wiki_export_modal}
            on_close="close_wiki_export_modal"
          >
            <.form for={%{}} phx-submit="confirm_wiki_export" class="space-y-4">
              <div class="form-control">
                <label class="label"><span class="label-text">Page Title</span></label>
                <input
                  type="text"
                  name="title"
                  value={@wiki_export_title}
                  class="input input-bordered w-full"
                  required
                />
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">Location</span></label>
                <select name="parent_id" class="select select-bordered w-full" required>
                  <option value="" disabled selected>Select a space...</option>
                  <%= for node <- @wiki_export_tree do %>
                    <WikiComponents.wiki_parent_option
                      node={node}
                      depth={0}
                      selected={@wiki_export_parent_id}
                    />
                  <% end %>
                </select>
              </div>
              <div class="flex justify-end gap-2 pt-2">
                <button type="button" phx-click="close_wiki_export_modal" class="btn btn-ghost btn-sm">
                  Cancel
                </button>
                <button type="submit" class="btn btn-primary btn-sm">Export</button>
              </div>
            </.form>
          </ChatComponents.modal>
        <% end %>
        <%= if ProfileLive.profile_action?(@live_action) do %>
          <ProfileLive.profile
            live_action={@live_action}
            current_user={@current_user}
            sidebar_open={@sidebar_open}
            password_form={@password_form}
            password_error={@password_error}
            password_success={@password_success}
            user_llm_providers={@user_llm_providers}
            user_editing_provider={@user_editing_provider}
            user_provider_form={@user_provider_form}
            user_llm_models={@user_llm_models}
            user_editing_model={@user_editing_model}
            user_model_form={@user_model_form}
          />
        <% end %>
        <%= if AdminLive.admin_action?(@live_action) do %>
          <AdminLive.admin_panel
            live_action={@live_action}
            current_user={@current_user}
            sidebar_open={@sidebar_open}
            single_user_mode={@single_user_mode}
            profile_users={@profile_users}
            profile_groups={@profile_groups}
            group_detail={@group_detail}
            group_members={@group_members}
            temp_password_user_id={@temp_password_user_id}
            llm_models={@llm_models}
            editing_llm_model={@editing_llm_model}
            llm_model_form={@llm_model_form}
            llm_providers={@llm_providers}
            editing_llm_provider={@editing_llm_provider}
            llm_provider_form={@llm_provider_form}
            server_settings={@server_settings}
            invitations={@invitations}
            new_invitation_url={@new_invitation_url}
            admin_usage_data={@admin_usage_data}
            admin_usage_period={@admin_usage_period}
            rbac_roles={@rbac_roles}
            editing_role={@editing_role}
            role_form={@role_form}
            role_users={@role_users}
            role_groups={@role_groups}
            role_user_search={@role_user_search}
            setup_steps={@setup_steps}
            setup_step={@setup_step}
            setup_form={@setup_form}
            setup_error={@setup_error}
            setup_selected_permissions={@setup_selected_permissions}
            setup_data_sources={@setup_data_sources}
            setup_selected_sources={@setup_selected_sources}
            setup_sources_to_configure={@setup_sources_to_configure}
            setup_current_config_index={@setup_current_config_index}
            setup_config_form={@setup_config_form}
            setup_llm_providers={@setup_llm_providers}
            setup_llm_models={@setup_llm_models}
            setup_llm_provider_form={@setup_llm_provider_form}
            setup_llm_model_form={@setup_llm_model_form}
            setup_rag_embedding_models={@setup_rag_embedding_models}
            setup_rag_current_model={@setup_rag_current_model}
            setup_provider_view={@setup_provider_view}
            rag_embedding_models={@rag_embedding_models}
            rag_current_model={@rag_current_model}
            rag_stats={@rag_stats}
            rag_confirm_change={@rag_confirm_change}
            rag_confirm_input={@rag_confirm_input}
            rag_selected_model_id={@rag_selected_model_id}
            rag_reembed_in_progress={@rag_reembed_in_progress}
            or_search={@or_search}
            or_results={@or_results}
            or_loading={@or_loading}
            embed_results_all={@embed_results_all}
            embed_search={@embed_search}
            embed_results={@embed_results}
          />
        <% end %>
        <%= if @settings_mode and @live_action == :settings_account do %>
          <ProfileLive.profile
            live_action={:info}
            current_user={@current_user}
            sidebar_open={@sidebar_open}
            password_form={@password_form}
            password_error={@password_error}
            password_success={@password_success}
            user_llm_providers={@user_llm_providers}
            user_editing_provider={@user_editing_provider}
            user_provider_form={@user_provider_form}
            user_llm_models={@user_llm_models}
            user_editing_model={@user_editing_model}
            user_model_form={@user_model_form}
            settings_mode={true}
            settings_action={@live_action}
          />
        <% end %>
        <%= if @settings_mode and SettingsLive.settings_action?(@live_action) and @live_action != :settings_account do %>
          <AdminLive.admin_panel
            live_action={SettingsLive.settings_to_admin_action(@live_action)}
            current_user={@current_user}
            sidebar_open={@sidebar_open}
            profile_users={@profile_users}
            profile_groups={@profile_groups}
            group_detail={@group_detail}
            group_members={@group_members}
            temp_password_user_id={@temp_password_user_id}
            llm_models={@llm_models}
            editing_llm_model={@editing_llm_model}
            llm_model_form={@llm_model_form}
            llm_providers={@llm_providers}
            editing_llm_provider={@editing_llm_provider}
            llm_provider_form={@llm_provider_form}
            server_settings={@server_settings}
            invitations={@invitations}
            new_invitation_url={@new_invitation_url}
            admin_usage_data={@admin_usage_data}
            admin_usage_period={@admin_usage_period}
            rbac_roles={@rbac_roles}
            editing_role={@editing_role}
            role_form={@role_form}
            role_users={@role_users}
            role_groups={@role_groups}
            role_user_search={@role_user_search}
            setup_steps={@setup_steps}
            setup_step={@setup_step}
            setup_form={@setup_form}
            setup_error={@setup_error}
            setup_selected_permissions={@setup_selected_permissions}
            setup_data_sources={@setup_data_sources}
            setup_selected_sources={@setup_selected_sources}
            setup_sources_to_configure={@setup_sources_to_configure}
            setup_current_config_index={@setup_current_config_index}
            setup_config_form={@setup_config_form}
            setup_llm_providers={@setup_llm_providers}
            setup_llm_models={@setup_llm_models}
            setup_llm_provider_form={@setup_llm_provider_form}
            setup_llm_model_form={@setup_llm_model_form}
            setup_rag_embedding_models={@setup_rag_embedding_models}
            setup_rag_current_model={@setup_rag_current_model}
            setup_provider_view={@setup_provider_view}
            rag_embedding_models={@rag_embedding_models}
            rag_current_model={@rag_current_model}
            rag_stats={@rag_stats}
            rag_confirm_change={@rag_confirm_change}
            rag_confirm_input={@rag_confirm_input}
            rag_selected_model_id={@rag_selected_model_id}
            rag_reembed_in_progress={@rag_reembed_in_progress}
            or_search={@or_search}
            or_results={@or_results}
            or_loading={@or_loading}
            embed_results_all={@embed_results_all}
            embed_search={@embed_search}
            embed_results={@embed_results}
            settings_mode={true}
            settings_action={@live_action}
          />
        <% end %>
        <%= if @live_action == :conversations do %>
          <div class="flex-1 flex flex-col min-w-0">
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
                  <h1 class="text-lg font-semibold">Conversations</h1>
                  <span class="text-sm text-base-content/50">
                    ({@conversations_total})
                  </span>
                </div>
                <div class="flex items-center gap-2">
                  <button
                    :if={MapSet.size(@conversations_selected) > 0}
                    phx-click="confirm_bulk_archive"
                    class="btn btn-error btn-sm gap-1"
                  >
                    <.icon name="hero-trash-micro" class="size-4" />
                    Archive ({MapSet.size(@conversations_selected)})
                  </button>
                </div>
              </div>
            </header>

            <div class="p-4 border-b border-base-300">
              <form phx-change="conversations_search" phx-submit="conversations_search">
                <input
                  type="text"
                  name="search"
                  value={@conversations_search}
                  placeholder="Search conversations..."
                  class="input input-bordered input-sm w-full max-w-sm"
                  phx-debounce="300"
                  autocomplete="off"
                />
              </form>
            </div>

            <div class="flex-1 overflow-y-auto">
              <div :if={@managed_conversations != []} class="divide-y divide-base-200">
                <div class="flex items-center gap-3 px-4 py-2 bg-base-200/50 text-xs text-base-content/60 sticky top-0">
                  <input
                    type="checkbox"
                    class="checkbox checkbox-sm checkbox-primary"
                    checked={
                      MapSet.size(@conversations_selected) == length(@managed_conversations) and
                        @managed_conversations != []
                    }
                    phx-click="toggle_select_all_conversations"
                  />
                  <span>Select all</span>
                </div>
                <div
                  :for={conv <- @managed_conversations}
                  class={[
                    "flex items-center gap-3 px-4 py-3 hover:bg-base-200/50 transition-colors",
                    MapSet.member?(@conversations_selected, conv.id) && "bg-primary/5"
                  ]}
                >
                  <input
                    type="checkbox"
                    class="checkbox checkbox-sm checkbox-primary"
                    checked={MapSet.member?(@conversations_selected, conv.id)}
                    phx-click="toggle_select_conversation"
                    phx-value-id={conv.id}
                  />
                  <.link navigate={~p"/c/#{conv.id}"} class="flex-1 min-w-0">
                    <p class="text-sm font-medium truncate">{conv.title}</p>
                    <p class="text-xs text-base-content/50">
                      {Calendar.strftime(conv.updated_at, "%b %d, %Y %H:%M")} · {conv.message_count ||
                        0} messages
                    </p>
                  </.link>
                  <button
                    phx-click="confirm_delete_conversation"
                    phx-value-id={conv.id}
                    class="btn btn-ghost btn-xs text-base-content/40 hover:text-error"
                  >
                    <.icon name="hero-trash-micro" class="size-3.5" />
                  </button>
                </div>
              </div>

              <p
                :if={@managed_conversations == []}
                class="text-base-content/50 text-center py-12"
              >
                {if @conversations_search != "",
                  do: "No conversations match your search.",
                  else: "No conversations yet."}
              </p>

              <div
                :if={@conversations_total > @conversations_page_size}
                class="flex justify-center items-center gap-2 py-4 border-t border-base-200"
              >
                <button
                  :if={@conversations_page > 1}
                  phx-click="conversations_page"
                  phx-value-page={@conversations_page - 1}
                  class="btn btn-ghost btn-sm"
                >
                  Previous
                </button>
                <span class="text-sm text-base-content/60">
                  Page {@conversations_page} of {ceil(@conversations_total / @conversations_page_size)}
                </span>
                <button
                  :if={@conversations_page * @conversations_page_size < @conversations_total}
                  phx-click="conversations_page"
                  phx-value-page={@conversations_page + 1}
                  class="btn btn-ghost btn-sm"
                >
                  Next
                </button>
              </div>
            </div>
          </div>

          <ChatComponents.confirm_modal
            show={@confirm_bulk_delete}
            title="Archive conversations"
            message={"Are you sure you want to archive #{MapSet.size(@conversations_selected)} conversation(s)?"}
            confirm_event="bulk_archive_conversations"
            cancel_event="cancel_bulk_archive"
            confirm_label="Archive"
          />
        <% end %>
        <%!-- Agent Studio: Landing --%>
        <%= if @live_action == :agent_studio do %>
          <AgentStudioComponents.agent_studio_landing sidebar_open={@sidebar_open} />
        <% end %>
        <%!-- Agent Studio: Agents --%>
        <%= if @live_action == :agents do %>
          <AgentStudioComponents.agents_page
            agents={@studio_agents}
            current_user={@current_user}
            sidebar_open={@sidebar_open}
            confirm_delete_agent_id={@confirm_delete_agent_id}
          />
        <% end %>
        <%!-- Agent Studio: New/Edit Agent --%>
        <%= if @live_action in [:agent_new, :agent_edit] do %>
          <AgentStudioComponents.agent_form_page
            form={@agent_form}
            editing={@editing_agent}
            available_models={@available_llm_models}
            available_mcp_servers={assigns[:available_mcp_servers] || []}
            sidebar_open={@sidebar_open}
          />
        <% end %>
        <%!-- Agent Studio: Agent Detail --%>
        <%= if @live_action == :agent_show && @studio_agent do %>
          <AgentStudioComponents.agent_show_page
            agent={@studio_agent}
            sidebar_open={@sidebar_open}
          />
        <% end %>
        <%!-- Agent Studio: Teams --%>
        <%= if @live_action == :teams do %>
          <AgentStudioComponents.teams_page
            teams={@studio_teams}
            current_user={@current_user}
            sidebar_open={@sidebar_open}
            confirm_delete_team_id={@confirm_delete_team_id}
          />
        <% end %>
        <%!-- Agent Studio: New/Edit Team --%>
        <%= if @live_action in [:team_new, :team_edit] do %>
          <AgentStudioComponents.team_form_page
            form={@team_form}
            editing={@editing_team}
            available_agents={assigns[:available_agents] || []}
            sidebar_open={@sidebar_open}
          />
        <% end %>
        <%!-- Agent Studio: Team Detail --%>
        <%= if @live_action == :team_show && @studio_team do %>
          <AgentStudioComponents.team_show_page
            team={@studio_team}
            sidebar_open={@sidebar_open}
          />
        <% end %>
        <%!-- Agent Studio: Runs --%>
        <%= if @live_action == :runs do %>
          <AgentStudioComponents.runs_page
            runs={@studio_runs}
            current_user={@current_user}
            sidebar_open={@sidebar_open}
            confirm_delete_run_id={@confirm_delete_run_id}
          />
        <% end %>
        <%!-- Agent Studio: New Run --%>
        <%= if @live_action == :run_new do %>
          <AgentStudioComponents.run_form_page
            form={@run_form}
            teams={@studio_teams}
            sidebar_open={@sidebar_open}
          />
        <% end %>
        <%!-- Agent Studio: Run Detail --%>
        <%= if @live_action == :run_show && @studio_run do %>
          <AgentStudioComponents.run_show_page
            run={@studio_run}
            current_user={@current_user}
            sidebar_open={@sidebar_open}
            run_usage={@run_usage}
            run_usage_by_model={@run_usage_by_model}
          />
        <% end %>
        <%!-- Agent Studio: Run Log Detail --%>
        <%= if @live_action == :run_log_show do %>
          <AgentStudioComponents.run_log_show_page
            run={@studio_run}
            log={@studio_log}
            sidebar_open={@sidebar_open}
          />
        <% end %>
        <%!-- Agent Studio: Schedules --%>
        <%= if @live_action == :schedules do %>
          <AgentStudioComponents.schedules_page
            schedules={@studio_schedules}
            current_user={@current_user}
            sidebar_open={@sidebar_open}
            confirm_delete_schedule_id={@confirm_delete_schedule_id}
          />
        <% end %>
        <%!-- Agent Studio: New Schedule --%>
        <%= if @live_action == :schedule_new do %>
          <AgentStudioComponents.schedule_form_page
            form={@schedule_form}
            teams={@studio_teams}
            sidebar_open={@sidebar_open}
          />
        <% end %>
        <%!-- Agent Studio: Schedule Detail --%>
        <%= if @live_action == :schedule_show && @studio_schedule do %>
          <AgentStudioComponents.schedule_show_page
            schedule={@studio_schedule}
            sidebar_open={@sidebar_open}
          />
        <% end %>
        <%= if @live_action not in [:sources, :source_show, :source_document_show, :mcp_servers, :reports, :report_show, :conversations, :pipeline, :agent_studio, :agents, :agent_new, :agent_show, :agent_edit, :teams, :team_new, :team_show, :team_edit, :runs, :run_new, :run_show, :run_log_show, :schedules, :schedule_new, :schedule_show] and not ProfileLive.profile_action?(@live_action) and not AdminLive.admin_action?(@live_action) and not SettingsLive.settings_action?(@live_action) do %>
          <%= if @conversation do %>
            <%!-- Active conversation --%>
            <div class="flex flex-1 min-w-0 overflow-hidden">
              <div class="flex-1 flex flex-col min-w-0">
                <header class="px-4 py-3 border-b border-base-300 flex-shrink-0">
                  <div class="flex items-center gap-2">
                    <button
                      :if={!@sidebar_open}
                      phx-click="toggle_sidebar"
                      class="btn btn-circle btn-ghost btn-sm"
                    >
                      <.icon name="hero-bars-3-micro" class="size-5" />
                    </button>
                    <h1 class="text-lg font-semibold truncate flex-1">{@conversation.title}</h1>
                    <.cost_limit_button
                      cost_limit={@cost_limit}
                      cost_limit_input={@cost_limit_input}
                      cost_limit_tokens={@cost_limit_tokens}
                      show_cost_popover={@show_cost_popover}
                    />
                    <button
                      phx-click="show_usage_modal"
                      class="btn btn-ghost btn-sm btn-square"
                      title="Usage info"
                    >
                      <.icon name="hero-information-circle-micro" class="size-4" />
                    </button>
                    <button
                      phx-click="open_sharing"
                      phx-value-entity-type="conversation"
                      phx-value-entity-id={@conversation.id}
                      class="btn btn-ghost btn-sm btn-square"
                      title="Share"
                    >
                      <.icon name="hero-share-micro" class="size-4" />
                    </button>
                  </div>
                </header>

                <div id="messages" phx-hook="ScrollBottom" class="flex-1 overflow-y-auto px-4 py-4">
                  <%= for msg <- display_messages(@messages, @editing_message_id) do %>
                    <ChatComponents.message_bubble
                      :if={msg.content && msg.content != ""}
                      message={msg}
                      can_edit={msg.role == "user" && !@streaming && @editing_message_id == nil}
                      editing={@editing_message_id == msg.id}
                      editing_content={@editing_message_content}
                      available_tools={@available_tools}
                      edit_selected_server_ids={@edit_selected_server_ids}
                      edit_show_tool_picker={@edit_show_tool_picker}
                      edit_auto_confirm={@edit_auto_confirm_tools}
                    />
                    <SourcesComponents.sources_button
                      :if={@editing_message_id != msg.id}
                      message={msg}
                    />
                    <%!-- Tool calls for completed messages (inline) --%>
                    <%= if msg.role == "assistant" && msg.stop_reason == "tool_use" do %>
                      <%= for tc <- MessageBuilder.tool_calls_for_message(msg) do %>
                        <McpComponents.tool_call_display
                          tool_call={tc}
                          show_actions={!@auto_confirm_tools && tc.status == "started"}
                        />
                      <% end %>
                    <% end %>
                    <ChatComponents.stream_error
                      :if={msg.status == "failed" && msg == List.last(@messages) && !@stream_error}
                      error={
                        %{
                          title: "The AI service was unavailable",
                          detail: "The response failed to generate. Click retry to try again."
                        }
                      }
                    />
                  <% end %>
                  <div :if={@streaming && @stream_content != ""} class="mb-4 text-base-content">
                    <div id="streaming-prose" phx-hook="CopyCode" class="prose prose-sm max-w-none">
                      {LiteskillWeb.Markdown.render_streaming(@stream_content)}
                    </div>
                  </div>
                  <ChatComponents.streaming_indicator :if={@streaming && @stream_content == ""} />
                  <%!-- Pending tool calls from streaming message (rendered from socket state, not DB) --%>
                  <%= for tc <- @pending_tool_calls do %>
                    <McpComponents.tool_call_display
                      tool_call={tc}
                      show_actions={!@auto_confirm_tools && tc.status == "started"}
                    />
                  <% end %>
                  <ChatComponents.stream_error :if={@stream_error} error={@stream_error} />
                </div>

                <div class="flex-shrink-0 border-t border-base-300 px-4 py-3">
                  <div class="flex items-center gap-2 mb-1">
                    <McpComponents.selected_server_badges
                      available_tools={@available_tools}
                      selected_server_ids={@selected_server_ids}
                    />
                  </div>
                  <.form
                    for={@form}
                    phx-submit="send_message"
                    phx-change="form_changed"
                    class="flex items-center gap-0 border border-base-300 rounded-xl bg-base-100 focus-within:border-primary/50 transition-colors"
                  >
                    <McpComponents.server_picker
                      available_tools={@available_tools}
                      selected_server_ids={@selected_server_ids}
                      show={@show_tool_picker}
                      auto_confirm={@auto_confirm_tools}
                      tools_loading={@tools_loading}
                    />
                    <textarea
                      id="message-input"
                      name="message[content]"
                      phx-hook="TextareaAutoResize"
                      placeholder="Type a message..."
                      rows="1"
                      class="flex-1 bg-transparent border-0 focus:outline-none focus:ring-0 resize-none min-h-[2.5rem] max-h-40 py-2 px-1 text-base-content placeholder:text-base-content/40"
                      disabled={@streaming}
                    >{Phoenix.HTML.Form.input_value(@form, :content)}</textarea>
                    <button
                      :if={!@streaming}
                      type="submit"
                      class="btn btn-ghost btn-sm text-primary hover:bg-primary/10 m-1"
                    >
                      <.icon name="hero-paper-airplane-micro" class="size-5" />
                    </button>
                    <button
                      :if={@streaming}
                      type="button"
                      phx-click="cancel_stream"
                      class="btn btn-ghost btn-sm text-error hover:bg-error/10 m-1"
                    >
                      <.icon name="hero-stop-micro" class="size-5" />
                    </button>
                  </.form>
                  <.model_picker
                    id="model-picker-conversation"
                    class="mt-1"
                    available_llm_models={@available_llm_models}
                    selected_llm_model_id={@selected_llm_model_id}
                  />
                </div>
              </div>
              <SourcesComponents.sources_sidebar
                show={@show_sources_sidebar}
                sources={@sidebar_sources}
              />
            </div>
          <% else %>
            <%!-- New conversation prompt --%>
            <div :if={!@sidebar_open} class="px-4 pt-3">
              <button phx-click="toggle_sidebar" class="btn btn-circle btn-ghost btn-sm">
                <.icon name="hero-bars-3-micro" class="size-5" />
              </button>
            </div>
            <div class="flex-1 flex items-center justify-center px-4">
              <div class="w-full max-w-xl text-center">
                <h1 class="text-3xl font-bold mb-8 text-base-content">
                  What can I help you with?
                </h1>
                <McpComponents.selected_server_badges
                  available_tools={@available_tools}
                  selected_server_ids={@selected_server_ids}
                />
                <.form
                  for={@form}
                  phx-submit="send_message"
                  phx-change="form_changed"
                  class="flex items-center gap-0 border border-base-300 rounded-xl bg-base-100 focus-within:border-primary/50 transition-colors"
                >
                  <McpComponents.server_picker
                    available_tools={@available_tools}
                    selected_server_ids={@selected_server_ids}
                    show={@show_tool_picker}
                    auto_confirm={@auto_confirm_tools}
                    tools_loading={@tools_loading}
                  />
                  <textarea
                    id="message-input"
                    name="message[content]"
                    phx-hook="TextareaAutoResize"
                    placeholder="Type a message..."
                    rows="1"
                    class="flex-1 bg-transparent border-0 focus:outline-none focus:ring-0 resize-none min-h-[2.5rem] max-h-40 py-2 px-1 text-base-content placeholder:text-base-content/40"
                  >{Phoenix.HTML.Form.input_value(@form, :content)}</textarea>
                  <button
                    type="submit"
                    class="btn btn-ghost btn-sm text-primary hover:bg-primary/10 m-1"
                  >
                    <.icon name="hero-paper-airplane-micro" class="size-5" />
                  </button>
                </.form>
                <div class="flex items-center justify-center gap-2 mt-2">
                  <.model_picker
                    id="model-picker-new"
                    available_llm_models={@available_llm_models}
                    selected_llm_model_id={@selected_llm_model_id}
                  />
                  <.cost_limit_button
                    cost_limit={@cost_limit}
                    cost_limit_input={@cost_limit_input}
                    cost_limit_tokens={@cost_limit_tokens}
                    show_cost_popover={@show_cost_popover}
                  />
                </div>
                <p
                  :if={@available_llm_models == []}
                  class="text-sm text-warning mt-2 px-1"
                >
                  No models configured.
                  <.link navigate={~p"/admin/models"} class="link link-primary">
                    Add one in Settings
                  </.link>
                </p>
              </div>
            </div>
          <% end %>
        <% end %>
      </main>

      <ChatComponents.modal
        id="tools-modal"
        title={if @inspecting_server, do: "#{@inspecting_server.name} — Tools", else: "Tools"}
        show={@inspecting_server != nil}
        on_close="close_tools_modal"
      >
        <div :if={@inspecting_tools_loading} class="text-center py-8 text-base-content/50">
          Loading tools...
        </div>
        <div
          :if={!@inspecting_tools_loading && @inspecting_tools == []}
          class="text-center py-8 text-base-content/50"
        >
          No tools found on this server.
        </div>
        <div :if={!@inspecting_tools_loading && @inspecting_tools != []} class="space-y-3">
          <McpComponents.tool_detail :for={tool <- @inspecting_tools} tool={tool} />
        </div>
      </ChatComponents.modal>

      <SourcesComponents.source_detail_modal
        show={@show_source_modal}
        source={@source_modal_data}
      />
      <SourcesComponents.raw_output_modal
        show={@show_raw_output_modal}
        raw_output={@raw_output_content}
        message_id={@raw_output_message_id}
      />

      <ChatComponents.confirm_modal
        show={@confirm_delete_id != nil}
        title="Archive conversation"
        message="Are you sure you want to archive this conversation?"
        confirm_event="delete_conversation"
        cancel_event="cancel_delete_conversation"
        confirm_label="Archive"
      />

      <McpComponents.tool_call_modal tool_call={@tool_call_modal} />

      <SharingComponents.sharing_modal
        show={@show_sharing}
        entity_type={@sharing_entity_type || "conversation"}
        entity_id={@sharing_entity_id}
        acls={@sharing_acls}
        user_search_results={@sharing_user_search_results}
        user_search_query={@sharing_user_search_query}
        groups={@sharing_groups}
        current_user_id={@current_user.id}
        error={@sharing_error}
      />

      <ChatComponents.modal
        id="usage-modal"
        title="Conversation Usage"
        show={@show_usage_modal}
        on_close="close_usage_modal"
      >
        <div :if={@usage_modal_data} class="space-y-4">
          <div class="grid grid-cols-3 gap-3">
            <div class="text-center p-3 bg-base-200 rounded-lg">
              <div class="text-xs text-base-content/60">Input Cost</div>
              <div class="text-lg font-bold">
                {format_cost(@usage_modal_data.totals.input_cost)}
              </div>
            </div>
            <div class="text-center p-3 bg-base-200 rounded-lg">
              <div class="text-xs text-base-content/60">Output Cost</div>
              <div class="text-lg font-bold">
                {format_cost(@usage_modal_data.totals.output_cost)}
              </div>
            </div>
            <div class="text-center p-3 bg-base-200 rounded-lg">
              <div class="text-xs text-base-content/60">Total Cost</div>
              <div class="text-lg font-bold">
                {format_cost(@usage_modal_data.totals.total_cost)}
              </div>
            </div>
          </div>

          <div class="text-sm text-base-content/60 grid grid-cols-3 gap-3">
            <div class="text-center">
              <span class="font-mono">
                {format_number(@usage_modal_data.totals.input_tokens)}
              </span>
              <span class="ml-1">in</span>
            </div>
            <div class="text-center">
              <span class="font-mono">
                {format_number(@usage_modal_data.totals.output_tokens)}
              </span>
              <span class="ml-1">out</span>
            </div>
            <div class="text-center">
              <span class="font-mono">
                {format_number(@usage_modal_data.totals.total_tokens)}
              </span>
              <span class="ml-1">total</span>
            </div>
          </div>

          <div :if={@usage_modal_data.by_model != []} class="divider my-2">By Model</div>

          <div :if={@usage_modal_data.by_model != []} class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Model</th>
                  <th class="text-right">In Cost</th>
                  <th class="text-right">Out Cost</th>
                  <th class="text-right">Total</th>
                  <th class="text-right">Calls</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @usage_modal_data.by_model}>
                  <td class="font-mono text-xs max-w-[200px] truncate">{row.model_id}</td>
                  <td class="text-right">{format_cost(row.input_cost)}</td>
                  <td class="text-right">{format_cost(row.output_cost)}</td>
                  <td class="text-right">{format_cost(row.total_cost)}</td>
                  <td class="text-right">{row.call_count}</td>
                </tr>
              </tbody>
            </table>
          </div>

          <p
            :if={@usage_modal_data.by_model == [] && @usage_modal_data.totals.call_count == 0}
            class="text-center text-base-content/50 py-4"
          >
            No usage data for this conversation yet.
          </p>
        </div>
      </ChatComponents.modal>
    </div>
    """
  end

  # --- Events ---

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, sidebar_open: !socket.assigns.sidebar_open)}
  end

  @impl true
  def handle_event("close_sidebar", _params, socket) do
    {:noreply, assign(socket, sidebar_open: false)}
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
          (source.metadata || %{})
          |> Map.filter(fn {k, _v} ->
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
  def handle_event(
        "save_source_config",
        %{"source_id" => source_id, "config" => config_params},
        socket
      ) do
    user_id = socket.assigns.current_user.id

    metadata =
      config_params
      |> Enum.reject(fn {_k, v} -> v == "" end)
      |> Map.new()

    result =
      if metadata != %{} do
        Liteskill.DataSources.update_source(source_id, %{metadata: metadata}, user_id)
      else
        {:ok, :noop}
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
      {:ok, _} ->
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
            e -> {:error, Exception.message(e)}
          end

        send(lv, {:rag_search_result, result})
      end)

      {:noreply,
       assign(socket, rag_query_loading: true, rag_query_results: [], rag_query_error: nil)}
    end
  end

  # --- Sources Sidebar Events ---

  @impl true
  def handle_event("toggle_sources_sidebar", %{"message-id" => message_id}, socket) do
    message = Enum.find(socket.assigns.messages, &(&1.id == message_id))

    if message && message.rag_sources not in [nil, []] do
      if socket.assigns.show_sources_sidebar do
        {:noreply, assign(socket, show_sources_sidebar: false, sidebar_sources: [])}
      else
        {:noreply,
         assign(socket, show_sources_sidebar: true, sidebar_sources: message.rag_sources)}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close_sources_sidebar", _params, socket) do
    {:noreply, assign(socket, show_sources_sidebar: false, sidebar_sources: [])}
  end

  @impl true
  def handle_event("show_source_modal", %{"chunk-id" => chunk_id}, socket) do
    source = Enum.find(socket.assigns.sidebar_sources, &(&1["chunk_id"] == chunk_id))

    if source do
      {:noreply, assign(socket, show_source_modal: true, source_modal_data: source)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close_source_modal", _params, socket) do
    {:noreply, assign(socket, show_source_modal: false)}
  end

  @impl true
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

  @impl true
  def handle_event("close_raw_output_modal", _params, socket) do
    {:noreply,
     assign(socket,
       show_raw_output_modal: false,
       raw_output_message_id: nil,
       raw_output_content: ""
     )}
  end

  @impl true
  def handle_event("raw_output_copied", _params, socket) do
    {:noreply, put_flash(socket, :info, "Raw output copied")}
  end

  @impl true
  def handle_event("show_source", %{"doc-id" => doc_id}, socket) do
    # Find the source in any assistant message's rag_sources
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

  # --- Agent Studio Event Delegation ---

  @studio_events ~w(save_agent validate_agent confirm_delete_agent cancel_delete_agent
    add_agent_tool remove_agent_tool add_opinion remove_opinion select_strategy
    save_team confirm_delete_team cancel_delete_team add_team_member remove_team_member
    save_run start_run rerun retry_run cancel_run confirm_delete_run cancel_delete_run
    save_schedule toggle_schedule confirm_delete_schedule cancel_delete_schedule)

  @impl true
  def handle_event(event, params, socket) when event in @studio_events do
    AgentStudioLive.handle_studio_event(event, params, socket)
  end

  @impl true
  def handle_event("delete_agent|" <> id, _params, socket) do
    AgentStudioLive.handle_studio_event("delete_agent", %{"id" => id}, socket)
  end

  @impl true
  def handle_event("delete_team|" <> id, _params, socket) do
    AgentStudioLive.handle_studio_event("delete_team", %{"id" => id}, socket)
  end

  @impl true
  def handle_event("delete_run|" <> id, _params, socket) do
    AgentStudioLive.handle_studio_event("delete_run", %{"id" => id}, socket)
  end

  @impl true
  def handle_event("delete_schedule|" <> id, _params, socket) do
    AgentStudioLive.handle_studio_event("delete_schedule", %{"id" => id}, socket)
  end

  @impl true
  def handle_event("select_conversation", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/c/#{id}")}
  end

  @impl true
  def handle_event("form_changed", %{"message" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: :message))}
  end

  @impl true
  def handle_event("send_message", %{"message" => %{"content" => content}}, socket) do
    content = String.trim(content)

    cond do
      content == "" ->
        {:noreply, socket}

      socket.assigns.available_llm_models == [] ->
        {:noreply,
         put_flash(socket, :error, "No models configured. Add one in Settings > Models.")}

      true ->
        user_id = socket.assigns.current_user.id
        tool_config = build_tool_config(socket)

        case socket.assigns.conversation do
          nil ->
            create_params = %{
              user_id: user_id,
              title: truncate_title(content),
              llm_model_id: socket.assigns.selected_llm_model_id
            }

            case Chat.create_conversation(create_params) do
              {:ok, conversation} ->
                case Chat.send_message(conversation.id, user_id, content,
                       tool_config: tool_config
                     ) do
                  {:ok, _message} ->
                    {:noreply, push_navigate(socket, to: "/c/#{conversation.id}?auto_stream=1")}

                  {:error, reason} ->
                    {:noreply, put_flash(socket, :error, action_error("send message", reason))}
                end

              {:error, reason} ->
                {:noreply, put_flash(socket, :error, action_error("create conversation", reason))}
            end

          conversation ->
            case Chat.send_message(conversation.id, user_id, content, tool_config: tool_config) do
              {:ok, _message} ->
                {:ok, messages} = Chat.list_messages(conversation.id, user_id)
                pid = trigger_llm_stream(conversation, user_id, socket, tool_config)

                {:noreply,
                 socket
                 |> assign(
                   messages: messages,
                   form: to_form(%{"content" => ""}, as: :message),
                   streaming: true,
                   stream_content: "",
                   stream_error: nil,
                   pending_tool_calls: [],
                   stream_task_pid: pid
                 )}

              {:error, reason} ->
                {:noreply, put_flash(socket, :error, action_error("send message", reason))}
            end
        end
    end
  end

  @impl true
  def handle_event("confirm_delete_conversation", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirm_delete_id: id)}
  end

  @impl true
  def handle_event("cancel_delete_conversation", _params, socket) do
    {:noreply, assign(socket, confirm_delete_id: nil)}
  end

  @impl true
  def handle_event("delete_conversation", _params, socket) do
    user_id = socket.assigns.current_user.id
    id = socket.assigns.confirm_delete_id

    case Chat.archive_conversation(id, user_id) do
      {:ok, _} ->
        conversations = Chat.list_conversations(user_id)
        socket = assign(socket, conversations: conversations, confirm_delete_id: nil)

        if socket.assigns.live_action == :conversations do
          {:noreply, refresh_managed_conversations(socket)}
        else
          {:noreply, push_navigate(socket, to: ~p"/")}
        end

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(confirm_delete_id: nil)
         |> put_flash(:error, action_error("delete conversation", reason))}
    end
  end

  # --- Conversations Management Events ---

  @impl true
  def handle_event("conversations_search", %{"search" => search}, socket) do
    search_term = String.trim(search)
    user_id = socket.assigns.current_user.id
    page_size = socket.assigns.conversations_page_size
    opts = if search_term != "", do: [search: search_term], else: []

    managed = Chat.list_conversations(user_id, [limit: page_size, offset: 0] ++ opts)
    total = Chat.count_conversations(user_id, opts)

    {:noreply,
     assign(socket,
       managed_conversations: managed,
       conversations_search: search_term,
       conversations_page: 1,
       conversations_total: total,
       conversations_selected: MapSet.new()
     )}
  end

  @impl true
  def handle_event("conversations_page", %{"page" => page}, socket) do
    page = safe_page(page)
    user_id = socket.assigns.current_user.id
    page_size = socket.assigns.conversations_page_size
    search = socket.assigns.conversations_search
    opts = if search != "", do: [search: search], else: []

    offset = (page - 1) * page_size
    managed = Chat.list_conversations(user_id, [limit: page_size, offset: offset] ++ opts)

    {:noreply,
     assign(socket,
       managed_conversations: managed,
       conversations_page: page,
       conversations_selected: MapSet.new()
     )}
  end

  @impl true
  def handle_event("toggle_select_conversation", %{"id" => id}, socket) do
    selected = socket.assigns.conversations_selected

    selected =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    {:noreply, assign(socket, conversations_selected: selected)}
  end

  @impl true
  def handle_event("toggle_select_all_conversations", _params, socket) do
    all_ids = socket.assigns.managed_conversations |> Enum.map(& &1.id) |> MapSet.new()
    selected = socket.assigns.conversations_selected

    selected =
      if MapSet.equal?(selected, all_ids) and MapSet.size(all_ids) > 0,
        do: MapSet.new(),
        else: all_ids

    {:noreply, assign(socket, conversations_selected: selected)}
  end

  @impl true
  def handle_event("confirm_bulk_archive", _params, socket) do
    {:noreply, assign(socket, confirm_bulk_delete: true)}
  end

  @impl true
  def handle_event("cancel_bulk_archive", _params, socket) do
    {:noreply, assign(socket, confirm_bulk_delete: false)}
  end

  @impl true
  def handle_event("bulk_archive_conversations", _params, socket) do
    user_id = socket.assigns.current_user.id
    ids = MapSet.to_list(socket.assigns.conversations_selected)
    total = length(ids)

    {:ok, archived} = Chat.bulk_archive_conversations(ids, user_id)

    conversations = Chat.list_conversations(user_id)

    socket =
      socket
      |> assign(
        conversations: conversations,
        confirm_bulk_delete: false,
        conversations_selected: MapSet.new()
      )
      |> refresh_managed_conversations()

    socket =
      if archived < total do
        put_flash(socket, :error, "Archived #{archived} of #{total} conversations")
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_stream", _params, socket) do
    # Kill the streaming task to stop token burn immediately
    if pid = socket.assigns.stream_task_pid do
      Process.exit(pid, :shutdown)
    end

    {:noreply, recover_stuck_stream(socket)}
  end

  @impl true
  def handle_event("retry_message", _params, socket) do
    conversation = socket.assigns.conversation
    user_id = socket.assigns.current_user.id

    if conversation do
      # Use tool config from the last user message (if any) for retry
      last_user_msg =
        socket.assigns.messages
        |> Enum.filter(&(&1.role == "user"))
        |> List.last()

      tool_config = if last_user_msg, do: last_user_msg.tool_config
      pid = trigger_llm_stream(conversation, user_id, socket, tool_config)

      {:noreply,
       socket
       |> assign(
         streaming: true,
         stream_content: "",
         stream_error: nil,
         pending_tool_calls: [],
         stream_task_pid: pid
       )}
    else
      {:noreply, socket}
    end
  end

  # --- Edit Message Events ---

  @impl true
  def handle_event("edit_message", %{"message-id" => message_id}, socket) do
    message = Enum.find(socket.assigns.messages, &(&1.id == message_id))

    if message do
      server_ids =
        case message.tool_config do
          %{"servers" => servers} when is_list(servers) ->
            servers |> Enum.map(& &1["id"]) |> MapSet.new()

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

  @impl true
  def handle_event("cancel_edit", _params, socket) do
    {:noreply, clear_edit_assigns(socket)}
  end

  @impl true
  def handle_event("confirm_edit", %{"content" => content}, socket) do
    content = String.trim(content)

    if content == "" do
      {:noreply, socket}
    else
      conversation = socket.assigns.conversation
      user_id = socket.assigns.current_user.id
      message_id = socket.assigns.editing_message_id
      tool_config = build_edit_tool_config(socket)

      case Chat.edit_message(conversation.id, user_id, message_id, content,
             tool_config: tool_config
           ) do
        {:ok, _message} ->
          {:ok, updated_conv} = Chat.get_conversation(conversation.id, user_id)
          pid = trigger_llm_stream(updated_conv, user_id, socket, tool_config)

          {:noreply,
           socket
           |> clear_edit_assigns()
           |> assign(
             conversation: updated_conv,
             messages: updated_conv.messages,
             streaming: true,
             stream_content: "",
             stream_error: nil,
             pending_tool_calls: [],
             stream_task_pid: pid
           )}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, action_error("edit message", reason))}
      end
    end
  end

  @impl true
  def handle_event("edit_form_changed", %{"content" => content}, socket) do
    {:noreply, assign(socket, editing_message_content: content)}
  end

  @impl true
  def handle_event("edit_toggle_tool_picker", _params, socket) do
    show = !socket.assigns.edit_show_tool_picker

    if show && socket.assigns.available_tools == [] do
      send(self(), :fetch_tools)
      {:noreply, assign(socket, edit_show_tool_picker: true, tools_loading: true)}
    else
      {:noreply, assign(socket, edit_show_tool_picker: show)}
    end
  end

  @impl true
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

  @impl true
  def handle_event("edit_toggle_auto_confirm", _params, socket) do
    {:noreply, assign(socket, edit_auto_confirm_tools: !socket.assigns.edit_auto_confirm_tools)}
  end

  @impl true
  def handle_event("edit_clear_tools", _params, socket) do
    {:noreply, assign(socket, edit_selected_server_ids: MapSet.new())}
  end

  @impl true
  def handle_event("edit_refresh_tools", _params, socket) do
    send(self(), :fetch_tools)
    {:noreply, assign(socket, tools_loading: true, available_tools: [])}
  end

  # --- Tool Picker Events ---

  @impl true
  def handle_event("select_llm_model", %{"model_id" => id}, socket) do
    user = socket.assigns.current_user
    Liteskill.Accounts.update_preferences(user, %{"preferred_llm_model_id" => id})

    # Keep cost fixed, recalculate tokens for new model
    tokens =
      if socket.assigns.cost_limit do
        estimate_tokens(socket.assigns.cost_limit, id, socket.assigns.available_llm_models)
      end

    {:noreply, assign(socket, selected_llm_model_id: id, cost_limit_tokens: tokens)}
  end

  @impl true
  def handle_event("toggle_cost_popover", _params, socket) do
    {:noreply, assign(socket, show_cost_popover: !socket.assigns.show_cost_popover)}
  end

  @impl true
  def handle_event("update_cost_limit", %{"cost" => ""}, socket) do
    {:noreply, assign(socket, cost_limit: nil, cost_limit_input: "", cost_limit_tokens: nil)}
  end

  def handle_event("update_cost_limit", %{"cost" => cost_str} = params, socket) do
    if params["_target"] == ["cost"] do
      case Decimal.parse(cost_str) do
        {cost, _} ->
          tokens =
            estimate_tokens(
              cost,
              socket.assigns.selected_llm_model_id,
              socket.assigns.available_llm_models
            )

          {:noreply,
           assign(socket,
             cost_limit: cost,
             cost_limit_input: cost_str,
             cost_limit_tokens: tokens
           )}

        :error ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("update_cost_limit", %{"tokens" => ""}, socket) do
    {:noreply, assign(socket, cost_limit: nil, cost_limit_input: "", cost_limit_tokens: nil)}
  end

  def handle_event("update_cost_limit", %{"tokens" => tokens_str} = params, socket) do
    if params["_target"] == ["tokens"] do
      case Integer.parse(tokens_str) do
        {tokens, _} when tokens > 0 ->
          cost =
            estimate_cost(
              tokens,
              socket.assigns.selected_llm_model_id,
              socket.assigns.available_llm_models
            )

          input_str = if cost, do: Decimal.to_string(Decimal.round(cost, 4)), else: ""

          {:noreply,
           assign(socket,
             cost_limit: cost,
             cost_limit_input: input_str,
             cost_limit_tokens: tokens
           )}

        _ ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("clear_cost_limit", _params, socket) do
    {:noreply,
     assign(socket,
       cost_limit: nil,
       cost_limit_input: "",
       cost_limit_tokens: nil,
       show_cost_popover: false
     )}
  end

  @impl true
  def handle_event("toggle_tool_picker", _params, socket) do
    show = !socket.assigns.show_tool_picker

    if show && socket.assigns.available_tools == [] do
      # Fetch tools when opening picker for the first time
      send(self(), :fetch_tools)
      {:noreply, assign(socket, show_tool_picker: true, tools_loading: true)}
    else
      {:noreply, assign(socket, show_tool_picker: show)}
    end
  end

  @impl true
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

  @impl true
  def handle_event("toggle_auto_confirm", _params, socket) do
    new_val = !socket.assigns.auto_confirm_tools
    user = socket.assigns.current_user
    Liteskill.Accounts.update_preferences(user, %{"auto_confirm_tools" => new_val})
    {:noreply, assign(socket, auto_confirm_tools: new_val)}
  end

  @impl true
  def handle_event("clear_tools", _params, socket) do
    McpServers.clear_selected_servers(socket.assigns.current_user.id)
    {:noreply, assign(socket, selected_server_ids: MapSet.new())}
  end

  @impl true
  def handle_event("refresh_tools", _params, socket) do
    send(self(), :fetch_tools)
    {:noreply, assign(socket, tools_loading: true, available_tools: [])}
  end

  @impl true
  def handle_event("approve_tool_call", %{"tool-use-id" => tool_use_id}, socket) do
    Chat.broadcast_tool_decision(socket.assigns.conversation.stream_id, tool_use_id, :approved)
    {:noreply, socket}
  end

  @impl true
  def handle_event("reject_tool_call", %{"tool-use-id" => tool_use_id}, socket) do
    Chat.broadcast_tool_decision(socket.assigns.conversation.stream_id, tool_use_id, :rejected)
    {:noreply, socket}
  end

  @impl true
  def handle_event("show_tool_call", %{"tool-use-id" => tool_use_id}, socket) do
    tc = find_tool_call(socket, tool_use_id)
    {:noreply, assign(socket, tool_call_modal: tc)}
  end

  @impl true
  def handle_event("close_tool_call_modal", _params, socket) do
    {:noreply, assign(socket, tool_call_modal: nil)}
  end

  @impl true
  def handle_event("show_usage_modal", _params, socket) do
    conv = socket.assigns.conversation

    if conv do
      totals = Liteskill.Usage.usage_by_conversation(conv.id)

      by_model =
        Liteskill.Usage.usage_summary(conversation_id: conv.id, group_by: :model_id)

      {:noreply,
       assign(socket,
         show_usage_modal: true,
         usage_modal_data: %{totals: totals, by_model: by_model}
       )}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close_usage_modal", _params, socket) do
    {:noreply, assign(socket, show_usage_modal: false)}
  end

  # --- MCP Server Events ---

  @impl true
  def handle_event("show_add_mcp", _params, socket) do
    {:noreply,
     assign(socket,
       show_mcp_modal: true,
       editing_mcp: nil,
       mcp_form:
         to_form(
           %{
             "name" => "",
             "url" => "",
             "api_key" => "",
             "description" => "",
             "headers" => "",
             "global" => false
           },
           as: :mcp_server
         )
     )}
  end

  @impl true
  def handle_event("edit_mcp", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case McpServers.get_server(id, user_id) do
      {:ok, server} ->
        headers_json =
          case server.headers do
            nil -> ""
            h when h == %{} -> ""
            h -> Jason.encode!(h, pretty: true)
          end

        {:noreply,
         assign(socket,
           show_mcp_modal: true,
           editing_mcp: server,
           mcp_form:
             to_form(
               %{
                 "name" => server.name,
                 "url" => server.url,
                 "api_key" => server.api_key || "",
                 "description" => server.description || "",
                 "headers" => headers_json,
                 "global" => server.global
               },
               as: :mcp_server
             )
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("load server", reason))}
    end
  end

  @impl true
  def handle_event("close_mcp_modal", _params, socket) do
    {:noreply, assign(socket, show_mcp_modal: false, editing_mcp: nil)}
  end

  @impl true
  def handle_event("save_mcp", %{"mcp_server" => params}, socket) do
    user_id = socket.assigns.current_user.id

    headers = parse_headers(params["headers"])
    attrs = Map.merge(params, %{"headers" => headers, "user_id" => user_id})

    result =
      case socket.assigns.editing_mcp do
        nil ->
          McpServers.create_server(attrs)

        server ->
          McpServers.update_server(server, user_id, attrs)
      end

    case result do
      {:ok, _server} ->
        servers = McpServers.list_servers(user_id)

        {:noreply,
         socket
         |> assign(mcp_servers: servers, show_mcp_modal: false, editing_mcp: nil)
         |> put_flash(:info, "Server saved")}

      {:error, %Ecto.Changeset{} = changeset} ->
        changeset = Map.put(changeset, :action, :validate)

        {:noreply,
         socket
         |> assign(mcp_form: to_form(changeset, as: :mcp_server))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("save server", reason))}
    end
  end

  @impl true
  def handle_event("delete_mcp", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case McpServers.delete_server(id, user_id) do
      {:ok, _} ->
        servers = McpServers.list_servers(user_id)
        {:noreply, assign(socket, mcp_servers: servers)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("delete server", reason))}
    end
  end

  # --- Pipeline Event Delegation ---

  @pipeline_events ~w(pipeline_toggle_scope pipeline_search_jobs
    pipeline_jobs_page pipeline_select_window)

  def handle_event(event, params, socket) when event in @pipeline_events do
    PipelineLive.handle_event(event, params, socket)
  end

  # --- Reports Event Delegation ---

  @reports_events ~w(delete_report leave_report export_report add_section_comment
    add_report_comment reply_to_comment report_edit_mode report_view_mode
    edit_section cancel_edit_section save_section open_wiki_export_modal
    close_wiki_export_modal confirm_wiki_export)

  def handle_event(event, params, socket) when event in @reports_events do
    ReportsLive.handle_event(event, params, socket)
  end

  @impl true
  def handle_event("address_comments", _params, socket) do
    user_id = socket.assigns.current_user.id
    report = socket.assigns.report

    system_prompt = Liteskill.Reports.address_comments_system_prompt()

    case Chat.create_conversation(%{
           user_id: user_id,
           title: "Address comments: #{report.title}",
           system_prompt: system_prompt
         }) do
      {:ok, conversation} ->
        content =
          "Please address all unaddressed comments on report #{report.id}. " <>
            "Read the report first, then update sections to address each open comment."

        # Pre-select Reports builtin tools and store config on the message
        socket = ensure_tools_loaded(socket)
        socket = select_reports_server(socket)
        tool_config = build_tool_config(socket)

        case Chat.send_message(conversation.id, user_id, content, tool_config: tool_config) do
          {:ok, _message} ->
            {:noreply, push_navigate(socket, to: "/c/#{conversation.id}?auto_stream=1")}

          # coveralls-ignore-start
          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Failed to send message")}
            # coveralls-ignore-stop
        end

      # coveralls-ignore-start
      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create conversation")}
        # coveralls-ignore-stop
    end
  end

  @impl true
  def handle_event("toggle_mcp_status", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case McpServers.get_server(id, user_id) do
      {:ok, server} ->
        new_status = if server.status == "active", do: "inactive", else: "active"

        case McpServers.update_server(server, user_id, %{"status" => new_status}) do
          {:ok, _} ->
            servers = McpServers.list_servers(user_id)
            {:noreply, assign(socket, mcp_servers: servers)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, action_error("update server status", reason))}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("load server", reason))}
    end
  end

  @impl true
  def handle_event("inspect_tools", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case McpServers.get_server(id, user_id) do
      {:ok, server} ->
        send(self(), {:fetch_server_tools, server})

        {:noreply,
         assign(socket,
           inspecting_server: server,
           inspecting_tools: [],
           inspecting_tools_loading: true
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("load server", reason))}
    end
  end

  @impl true
  def handle_event("close_tools_modal", _params, socket) do
    {:noreply,
     assign(socket, inspecting_server: nil, inspecting_tools: [], inspecting_tools_loading: false)}
  end

  # --- Profile Event Delegation ---

  @profile_events ~w(change_password set_accent_color
    user_new_provider user_cancel_provider user_create_provider
    user_edit_provider user_update_provider user_delete_provider
    user_new_model user_cancel_model user_create_model
    user_edit_model user_update_model user_delete_model)

  def handle_event(event, params, socket) when event in @profile_events do
    ProfileLive.handle_event(event, params, socket)
  end

  # --- Admin Event Delegation ---

  @admin_events ~w(admin_usage_period promote_user demote_user create_group
    admin_delete_group view_group admin_add_member admin_remove_member
    show_temp_password_form cancel_temp_password set_temp_password
    toggle_registration toggle_allow_private_mcp_urls update_mcp_cost_limit
    create_invitation revoke_invitation
    new_llm_model cancel_llm_model create_llm_model edit_llm_model update_llm_model delete_llm_model
    new_llm_provider cancel_llm_provider create_llm_provider edit_llm_provider update_llm_provider delete_llm_provider
    new_role cancel_role edit_role create_role update_role delete_role
    assign_role_user remove_role_user assign_role_group remove_role_group
    setup_password setup_skip_password
    setup_toggle_permission setup_save_permissions setup_skip_permissions
    setup_create_provider setup_providers_continue setup_providers_skip
    setup_openrouter_connect
    setup_providers_show_custom setup_providers_show_presets
    setup_create_model setup_models_continue setup_models_skip
    setup_select_embedding setup_rag_skip
    setup_toggle_source setup_save_sources
    setup_save_config setup_skip_config setup_skip_sources
    or_search or_select_model
    embed_search embed_select_model
    rag_select_model rag_cancel_change rag_confirm_input_change rag_confirm_model_change)

  def handle_event(event, params, socket) when event in @admin_events do
    AdminLive.handle_event(event, params, socket)
  end

  # --- Sharing Modal Events ---

  @sharing_events SharingLive.sharing_events()

  @impl true
  def handle_event(event, params, socket) when event in @sharing_events do
    SharingLive.handle_event(event, params, socket)
  end

  # --- PubSub Handlers ---

  @impl true
  def handle_info(:openrouter_connected, socket) do
    {:noreply,
     assign(socket,
       setup_openrouter_pending: false,
       setup_llm_providers: Liteskill.LlmProviders.list_all_providers()
     )}
  end

  def handle_info({:run_updated, _run} = msg, socket) do
    AgentStudioLive.handle_run_info(msg, socket)
  end

  def handle_info({:run_log_added, _log} = msg, socket) do
    AgentStudioLive.handle_run_info(msg, socket)
  end

  def handle_info({:events, _stream_id, events}, socket) do
    socket = Enum.reduce(events, socket, &handle_event_store_event/2)
    {:noreply, socket}
  end

  def handle_info(:reload_after_complete, socket) do
    case socket.assigns.conversation do
      nil ->
        {:noreply, socket}

      conversation ->
        user_id = socket.assigns.current_user.id

        {:ok, messages} = Chat.list_messages(conversation.id, user_id)
        conversations = Chat.list_conversations(user_id)

        # Reload conversation to check actual status — avoids race when
        # StreamHandler immediately starts a new round after completing
        {:ok, fresh_conv} = Chat.get_conversation(conversation.id, user_id)

        # The stream task runs the entire multi-round loop (including tool calls).
        # Between rounds the DB status is "active", but the task is still working.
        # Keep the typing indicator alive while the task process is running.
        task_alive = task_alive?(socket.assigns.stream_task_pid)
        still_streaming = fresh_conv.status == "streaming" || task_alive

        # Preserve stream_content only when actually mid-stream (DB says "streaming").
        # Between rounds (task alive, DB "active") clear it so the typing indicator shows
        # and the already-committed text doesn't duplicate the DB messages.
        db_streaming = fresh_conv.status == "streaming"

        {:noreply,
         assign(socket,
           streaming: still_streaming,
           stream_content: if(db_streaming, do: socket.assigns.stream_content, else: ""),
           messages: messages,
           conversations: conversations,
           conversation: fresh_conv,
           pending_tool_calls:
             if(task_alive && db_streaming, do: socket.assigns.pending_tool_calls, else: []),
           stream_task_pid: if(still_streaming, do: socket.assigns.stream_task_pid, else: nil)
         )}
    end
  end

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
            {tools_acc, errors_acc ++ ["#{server.name}: #{format_tool_error(reason)}"]}
        end
      end)

    socket = assign(socket, available_tools: builtin_tools ++ mcp_tools, tools_loading: false)

    socket =
      if errors != [] do
        put_flash(socket, :error, "Tool fetch failed: " <> Enum.join(errors, "; "))
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:fetch_server_tools, %{builtin: module}}, socket) do
    tools = module.list_tools()
    {:noreply, assign(socket, inspecting_tools: tools, inspecting_tools_loading: false)}
  end

  def handle_info({:fetch_server_tools, server}, socket) do
    case McpClient.list_tools(server) do
      {:ok, tools} ->
        {:noreply, assign(socket, inspecting_tools: tools, inspecting_tools_loading: false)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(inspecting_tools_loading: false)
         |> put_flash(:error, "Failed to fetch tools: #{format_tool_error(reason)}")}
    end
  end

  def handle_info({:rag_search_result, {:ok, results}}, socket) do
    chunks = Enum.map(results, & &1.chunk)
    preloaded = Repo.preload(chunks, document: :source)

    enriched =
      Enum.zip_with(results, preloaded, fn result, chunk ->
        %{result | chunk: chunk}
      end)

    {:noreply, assign(socket, rag_query_loading: false, rag_query_results: enriched)}
  end

  def handle_info({:rag_search_result, {:error, reason}}, socket) do
    message =
      case reason do
        %{status: status} -> "Search failed (HTTP #{status})"
        _ -> "Search failed"
      end

    {:noreply,
     assign(socket, rag_query_loading: false, rag_query_results: [], rag_query_error: message)}
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
          if db_pending != [] do
            db_pending
          else
            if socket.assigns.streaming && socket.assigns.pending_tool_calls != [] do
              socket.assigns.pending_tool_calls
            else
              []
            end
          end

        {:noreply, assign(socket, messages: messages, pending_tool_calls: pending)}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, socket) do
    if socket.assigns.streaming && pid == socket.assigns.stream_task_pid do
      {:noreply, recover_stuck_stream(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:pipeline_refresh, socket) do
    PipelineLive.handle_info(:pipeline_refresh, socket)
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  attr :id, :string, required: true
  attr :class, :string, default: ""
  attr :available_llm_models, :list, required: true
  attr :selected_llm_model_id, :string, default: nil

  defp model_picker(assigns) do
    ~H"""
    <div :if={@available_llm_models != []} class={["flex items-center gap-1 px-1", @class]}>
      <.icon name="hero-cpu-chip-micro" class="size-3 text-base-content/40" />
      <form phx-change="select_llm_model">
        <select
          id={@id}
          name="model_id"
          class="select select-ghost select-xs text-xs text-base-content/50 hover:text-base-content/70 min-h-0 h-6 pl-0"
        >
          <%= for m <- @available_llm_models do %>
            <option value={m.id} selected={m.id == @selected_llm_model_id}>
              {m.name}
            </option>
          <% end %>
        </select>
      </form>
    </div>
    """
  end

  attr :cost_limit, :any, default: nil
  attr :cost_limit_input, :string, default: ""
  attr :cost_limit_tokens, :any, default: nil
  attr :show_cost_popover, :boolean, default: false

  defp cost_limit_button(assigns) do
    ~H"""
    <div class="relative">
      <button
        type="button"
        phx-click="toggle_cost_popover"
        class={[
          "btn btn-ghost btn-sm btn-square",
          if(@cost_limit, do: "text-warning", else: "text-base-content/50")
        ]}
        title={if @cost_limit, do: "Cost limit: $#{@cost_limit_input}", else: "Set cost limit"}
      >
        <.icon name="hero-currency-dollar-micro" class="size-4" />
      </button>
      <div
        :if={@show_cost_popover}
        class="absolute top-full right-0 mt-1 z-50"
        phx-click-away="toggle_cost_popover"
      >
        <div class="card bg-base-100 shadow-xl border border-base-300 p-3 w-56">
          <h4 class="text-xs font-semibold mb-2">Cost Guardrail</h4>
          <span :if={@cost_limit} class="badge badge-warning badge-sm mb-2">
            ${@cost_limit_input}
            <span :if={@cost_limit_tokens} class="ml-1 opacity-70">
              (~{@cost_limit_tokens} tokens)
            </span>
          </span>
          <form phx-change="update_cost_limit">
            <div class="flex gap-2">
              <div class="form-control flex-1">
                <label class="text-xs text-base-content/60 mb-0.5">Cost ($)</label>
                <input
                  name="cost"
                  type="number"
                  step="0.01"
                  min="0"
                  value={@cost_limit_input}
                  class="input input-xs input-bordered w-full"
                  placeholder="0.50"
                />
              </div>
              <div class="form-control flex-1">
                <label class="text-xs text-base-content/60 mb-0.5">Tokens</label>
                <input
                  name="tokens"
                  type="number"
                  step="1000"
                  min="0"
                  value={@cost_limit_tokens}
                  class="input input-xs input-bordered w-full"
                  placeholder="—"
                />
              </div>
            </div>
          </form>
          <button
            type="button"
            phx-click="clear_cost_limit"
            class="btn btn-ghost btn-xs mt-2 w-full text-base-content/50"
          >
            No limit
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp handle_event_store_event(
         %{event_type: "AssistantStreamStarted"},
         socket
       ) do
    # Clear pending_tool_calls — previous round's tool calls are now in the DB
    # and rendered inline on their parent message.
    assign(socket,
      streaming: true,
      stream_content: "",
      stream_error: nil,
      pending_tool_calls: []
    )
  end

  defp handle_event_store_event(
         %{event_type: "AssistantChunkReceived", data: data},
         socket
       ) do
    delta = data["delta_text"] || ""
    assign(socket, stream_content: socket.assigns.stream_content <> delta)
  end

  defp handle_event_store_event(
         %{event_type: "AssistantStreamCompleted"},
         socket
       ) do
    # Delay reload to let the Projector finish updating the DB.
    # Keep streaming content visible until then.
    Process.send_after(self(), :reload_after_complete, 100)
    socket
  end

  defp handle_event_store_event(
         %{event_type: "AssistantStreamFailed", data: data},
         socket
       ) do
    error = friendly_stream_error(data["error_type"], data["error_message"])

    socket
    |> assign(streaming: false, stream_content: "", stream_error: error)
  end

  defp handle_event_store_event(
         %{event_type: "UserMessageAdded"},
         socket
       ) do
    # Reload messages (handles shared conversations)
    user_id = socket.assigns.current_user.id
    conversation = socket.assigns.conversation
    {:ok, messages} = Chat.list_messages(conversation.id, user_id)
    assign(socket, messages: messages)
  end

  defp handle_event_store_event(
         %{event_type: "ToolCallStarted", data: data},
         socket
       ) do
    # Build tool call immediately from event data to avoid race with projector
    tc = %ToolCall{
      tool_use_id: data["tool_use_id"],
      tool_name: data["tool_name"],
      input: data["input"],
      status: "started",
      message_id: data["message_id"]
    }

    pending = socket.assigns.pending_tool_calls ++ [tc]

    # Also schedule a DB reload to sync fully
    Process.send_after(self(), :reload_tool_calls, 500)
    assign(socket, pending_tool_calls: pending)
  end

  defp handle_event_store_event(
         %{event_type: "ToolCallCompleted", data: data},
         socket
       ) do
    # Update the pending tool call status immediately
    tool_use_id = data["tool_use_id"]

    pending =
      Enum.map(socket.assigns.pending_tool_calls, fn tc ->
        if tc.tool_use_id == tool_use_id do
          %{tc | status: "completed", output: data["output"]}
        else
          tc
        end
      end)

    # Also schedule a DB reload to sync fully
    Process.send_after(self(), :reload_tool_calls, 500)
    assign(socket, pending_tool_calls: pending)
  end

  defp handle_event_store_event(_event, socket), do: socket

  # --- Cost guardrail helpers ---

  defp estimate_tokens(cost_decimal, model_id, models) do
    zero = Decimal.new(0)

    case Enum.find(models, &(&1.id == model_id)) do
      %{input_cost_per_million: rate} when not is_nil(rate) ->
        if Decimal.compare(rate, zero) != :eq do
          cost_decimal
          |> Decimal.div(rate)
          |> Decimal.mult(1_000_000)
          |> Decimal.round(0)
          |> Decimal.to_integer()
        end

      _ ->
        nil
    end
  end

  defp estimate_cost(tokens, model_id, models) do
    case Enum.find(models, &(&1.id == model_id)) do
      %{input_cost_per_million: rate} when not is_nil(rate) ->
        Decimal.new(tokens)
        |> Decimal.mult(rate)
        |> Decimal.div(1_000_000)

      _ ->
        nil
    end
  end

  # --- Helpers ---

  defp trigger_llm_stream(conversation, user_id, socket, tool_config) do
    {:ok, messages} = Chat.list_messages(conversation.id, user_id)

    tool_opts =
      if tool_config do
        build_tool_opts_from_config(tool_config, user_id)
      else
        build_tool_opts(socket)
      end

    has_tools = Keyword.has_key?(tool_opts, :tools)

    llm_messages = MessageBuilder.build_llm_messages(messages)
    # Strip toolUse/toolResult blocks when no tools are selected — Bedrock
    # returns 400 if messages contain toolUse but no tools config is provided.
    llm_messages =
      if has_tools, do: llm_messages, else: MessageBuilder.strip_tool_blocks(llm_messages)

    # RAG context augmentation
    last_user_msg = messages |> Enum.filter(&(&1.role == "user")) |> List.last()
    query = if last_user_msg, do: last_user_msg.content

    {rag_results, rag_sources_json} =
      if query && String.trim(query) != "" do
        case Liteskill.Rag.augment_context(query, user_id) do
          {:ok, results} when results != [] ->
            {results, Liteskill.LLM.RagContext.serialize_sources(results)}

          _ ->
            {[], nil}
        end
      else
        {[], nil}
      end

    system_prompt =
      Liteskill.LLM.RagContext.build_system_prompt(rag_results, conversation.system_prompt)

    opts = if system_prompt, do: [system: system_prompt], else: []

    # Always pass user_id and conversation_id for usage tracking
    opts = [{:user_id, user_id}, {:conversation_id, conversation.id} | opts]

    # Cost guardrail
    opts =
      if socket.assigns.cost_limit do
        [{:cost_limit, socket.assigns.cost_limit} | opts]
      else
        opts
      end

    # Add tool options if tools are selected
    opts = opts ++ tool_opts

    # Pass rag_sources through the event store so they survive navigation
    opts = if rag_sources_json, do: [{:rag_sources, rag_sources_json} | opts], else: opts

    # Load LLM model config from UI-selected model
    opts =
      case socket.assigns[:selected_llm_model_id] do
        nil ->
          opts

        model_id ->
          case Liteskill.LlmModels.get_model(model_id, user_id) do
            {:ok, llm_model} -> [{:llm_model, llm_model} | opts]
            _ -> opts
          end
      end

    # Strip tools if model doesn't support them (e.g. Llama models on Bedrock)
    # Admins set {"supports_tools": false} in model config.
    {opts, llm_messages} =
      case Keyword.get(opts, :llm_model) do
        %{model_config: %{"supports_tools" => false}} ->
          stripped_opts = Keyword.drop(opts, [:tools, :tool_servers, :auto_confirm])
          {stripped_opts, MessageBuilder.strip_tool_blocks(llm_messages)}

        _ ->
          {opts, llm_messages}
      end

    {:ok, pid} =
      Task.Supervisor.start_child(Liteskill.TaskSupervisor, fn ->
        StreamHandler.handle_stream(conversation.stream_id, llm_messages, opts)
      end)

    Process.monitor(pid)
    pid
  end

  defp build_tool_opts(socket) do
    selected = socket.assigns.selected_server_ids
    available = socket.assigns.available_tools

    # Select all tools from selected servers
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

  defp build_tool_config(socket) do
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

  defp build_edit_tool_config(socket) do
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

  defp clear_edit_assigns(socket) do
    assign(socket,
      editing_message_id: nil,
      editing_message_content: "",
      edit_selected_server_ids: MapSet.new(),
      edit_show_tool_picker: false,
      edit_auto_confirm_tools: true
    )
  end

  defp display_messages(messages, nil), do: messages

  defp display_messages(messages, editing_message_id) do
    # Show messages up to and including the one being edited
    (Enum.take_while(messages, &(&1.id != editing_message_id)) ++
       [Enum.find(messages, &(&1.id == editing_message_id))])
    |> Enum.reject(&is_nil/1)
  end

  defp build_tool_opts_from_config(nil, _user_id), do: []

  defp build_tool_opts_from_config(tool_config, user_id) do
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

  defp ensure_tools_loaded(socket) do
    if socket.assigns.available_tools == [] do
      user_id = socket.assigns.current_user.id
      servers = Liteskill.McpServers.list_servers(user_id)
      active_servers = Enum.filter(servers, &(&1.status == "active"))

      builtin_tools =
        active_servers
        |> Enum.filter(&Map.has_key?(&1, :builtin))
        |> Enum.flat_map(fn server ->
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

      assign(socket, available_tools: builtin_tools)
    else
      socket
    end
  end

  defp select_reports_server(socket) do
    reports_server =
      Enum.find(socket.assigns.available_tools, fn tool ->
        String.starts_with?(tool.name, "reports__")
      end)

    case reports_server do
      nil ->
        socket

      tool ->
        assign(socket, selected_server_ids: MapSet.new([tool.server_id]))
    end
  end

  defp find_tool_call(socket, tool_use_id) do
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

  defp load_pending_tool_calls(messages) do
    case List.last(messages) do
      %{role: "assistant", stop_reason: "tool_use"} = msg ->
        MessageBuilder.tool_calls_for_message(msg)
        |> Enum.filter(&(&1.status == "started"))

      _ ->
        []
    end
  end

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

  defp maybe_unsubscribe(socket) do
    case socket.assigns[:conversation] do
      %{stream_id: stream_id} when not is_nil(stream_id) ->
        Phoenix.PubSub.unsubscribe(Liteskill.PubSub, "event_store:#{stream_id}")

      _ ->
        :ok
    end

    AgentStudioLive.maybe_unsubscribe_run(socket)
  end

  defp refresh_managed_conversations(socket) do
    user_id = socket.assigns.current_user.id
    page_size = socket.assigns.conversations_page_size
    search = socket.assigns.conversations_search
    opts = if search != "", do: [search: search], else: []

    offset = (socket.assigns.conversations_page - 1) * page_size
    managed = Chat.list_conversations(user_id, [limit: page_size, offset: offset] ++ opts)
    total = Chat.count_conversations(user_id, opts)

    assign(socket,
      managed_conversations: managed,
      conversations_total: total
    )
  end

  defp truncate_title(content) do
    case String.split(content, "\n", parts: 2) do
      [first | _] ->
        if String.length(first) > 50 do
          String.slice(first, 0, 47) <> "..."
        else
          first
        end
    end
  end

  defp parse_headers(str) when is_binary(str) do
    str = String.trim(str)

    if str == "" do
      %{}
    else
      case Jason.decode(str) do
        {:ok, map} when is_map(map) -> map
        _ -> %{}
      end
    end
  end

  defp parse_headers(_), do: %{}

  defp mcp_headers_value(val) when is_map(val) and val != %{},
    do: Jason.encode!(val, pretty: true)

  defp mcp_headers_value(val) when is_binary(val), do: val
  defp mcp_headers_value(_), do: ""

  defp recover_stuck_stream(socket) do
    conversation = socket.assigns.conversation

    if conversation do
      user_id = socket.assigns.current_user.id

      Chat.recover_stream(conversation.id, user_id)
      _ = :sys.get_state(Liteskill.Chat.Projector)

      {:ok, messages} = Chat.list_messages(conversation.id, user_id)
      {:ok, fresh_conv} = Chat.get_conversation(conversation.id, user_id)

      socket
      |> assign(
        streaming: false,
        stream_content: "",
        messages: messages,
        conversation: fresh_conv,
        pending_tool_calls: [],
        stream_task_pid: nil
      )
    else
      assign(socket, streaming: false, stream_content: "", stream_task_pid: nil)
    end
  end

  defp task_alive?(nil), do: false
  defp task_alive?(pid), do: Process.alive?(pid)

  defp find_source_by_doc_id(messages, doc_id) do
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

  defp lookup_source_from_db(doc_id, user_id) do
    alias Liteskill.Rag

    with {:ok, doc} <- Rag.get_document(doc_id, user_id) do
      doc = Liteskill.Repo.preload(doc, :source)
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
    else
      _ -> nil
    end
  end

  defp format_tool_error(%{status: status, body: body}) when is_binary(body),
    do: "HTTP #{status}: #{String.slice(body, 0..100)}"

  defp format_tool_error(%{status: status}), do: "HTTP #{status}"
  defp format_tool_error(%Req.TransportError{reason: reason}), do: "Connection error: #{reason}"
  defp format_tool_error(reason) when is_binary(reason), do: reason
  defp format_tool_error(_reason), do: "unexpected error"

  defp friendly_stream_error("max_retries_exceeded", _msg) do
    %{
      title: "The AI service is currently busy",
      detail: "Too many requests — please wait a moment and retry."
    }
  end

  defp friendly_stream_error("request_error", msg) when is_binary(msg) and msg != "" do
    %{
      title: "LLM request failed",
      detail: clean_error_detail(msg)
    }
  end

  defp friendly_stream_error(_type, msg) when is_binary(msg) and msg != "" do
    %{
      title: "Something went wrong",
      detail: clean_error_detail(msg)
    }
  end

  defp friendly_stream_error(_type, _msg) do
    %{
      title: "Something went wrong",
      detail: "An unexpected error occurred. Please try again."
    }
  end

  # Extract meaningful message from raw struct text that may have leaked into stored errors
  defp clean_error_detail(msg) do
    case Regex.run(~r/"message" => "([^"]+)"/, msg) do
      [_, extracted] ->
        case Regex.run(~r/^HTTP (\d+):/, msg) do
          [_, status] -> "HTTP #{status}: #{extracted}"
          nil -> extracted
        end

      nil ->
        msg
    end
  end

  defp safe_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  defp safe_page(page) when is_integer(page) and page > 0, do: page
  defp safe_page(_), do: 1
end
