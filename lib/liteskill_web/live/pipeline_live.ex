defmodule LiteskillWeb.PipelineLive do
  @moduledoc """
  Pipeline dashboard event handlers and helpers, rendered within ChatLive's main area.
  """

  use LiteskillWeb, :live_view

  alias Liteskill.Chat
  alias Liteskill.Rag.Pipeline
  alias LiteskillWeb.Layouts
  alias LiteskillWeb.PipelineComponents

  @refresh_interval_ms 5_000

  def pipeline_assigns do
    [
      pipeline_stats: %{
        source_count: 0,
        document_count: 0,
        chunk_count: 0,
        jobs_ok: 0,
        jobs_failed: 0,
        embed_requests: 0,
        embed_errors: 0
      },
      pipeline_rates: %{},
      pipeline_chart_data: [],
      pipeline_jobs: %{jobs: [], page: 1, page_size: 20, total: 0, total_pages: 1},
      pipeline_job_search: "",
      pipeline_scope: :user,
      pipeline_is_admin: false,
      pipeline_window: :hour
    ]
  end

  # --- LiveView callbacks ---

  @impl true
  def mount(_params, _session, socket) do
    conversations = Chat.list_conversations(socket.assigns.current_user.id)

    {:ok,
     socket
     |> assign(pipeline_assigns())
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
    {:noreply, apply_pipeline_action(socket, socket.assigns.live_action, params)}
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
        single_user_mode={@single_user_mode}
      />

      <main class="flex-1 flex flex-col min-w-0">
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
      </main>
    </div>
    """
  end

  def apply_pipeline_action(socket, :pipeline, _params) do
    user = socket.assigns.current_user
    is_admin = Liteskill.Rbac.has_permission?(user.id, "sources:manage_all")
    scope = :user

    socket
    |> assign(
      conversation: nil,
      messages: [],
      streaming: false,
      stream_content: "",
      pending_tool_calls: [],
      wiki_sidebar_tree: [],
      pipeline_is_admin: is_admin,
      pipeline_scope: scope,
      pipeline_job_search: "",
      pipeline_window: :hour,
      page_title: "RAG Pipeline"
    )
    |> load_pipeline_data(user.id, scope)
    |> schedule_pipeline_refresh()
  end

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, sidebar_open: !socket.assigns.sidebar_open)}
  end

  @impl true
  def handle_event("select_conversation", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: "/c/#{id}")}
  end

  @impl true
  def handle_event("pipeline_toggle_scope", _params, socket) do
    new_scope = if socket.assigns.pipeline_scope == :user, do: :all, else: :user
    user_id = socket.assigns.current_user.id

    socket =
      socket
      |> assign(pipeline_scope: new_scope)
      |> load_pipeline_data(user_id, new_scope)

    {:noreply, socket}
  end

  @impl true
  def handle_event("pipeline_search_jobs", %{"search" => search}, socket) do
    user_id = socket.assigns.current_user.id
    scope = socket.assigns.pipeline_scope

    jobs =
      Pipeline.list_jobs(user_id, scope: scope, page: 1, search: search)

    {:noreply,
     assign(socket,
       pipeline_job_search: search,
       pipeline_jobs: jobs
     )}
  end

  @impl true
  def handle_event("pipeline_jobs_page", %{"page" => page}, socket) do
    {page, _} = Integer.parse(page)
    user_id = socket.assigns.current_user.id
    scope = socket.assigns.pipeline_scope
    search = socket.assigns.pipeline_job_search

    jobs =
      Pipeline.list_jobs(user_id,
        scope: scope,
        page: page,
        search: if(search == "", do: nil, else: search)
      )

    {:noreply, assign(socket, pipeline_jobs: jobs)}
  end

  @impl true
  def handle_event("pipeline_select_window", %{"window" => window}, socket) do
    window = String.to_existing_atom(window)
    {:noreply, assign(socket, pipeline_window: window)}
  end

  @impl true
  def handle_info(:pipeline_refresh, socket) do
    if socket.assigns.live_action == :pipeline do
      user_id = socket.assigns.current_user.id
      scope = socket.assigns.pipeline_scope

      socket =
        socket
        |> load_pipeline_data(user_id, scope)
        |> schedule_pipeline_refresh()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Helpers ---

  defp load_pipeline_data(socket, user_id, scope) do
    stats = Pipeline.aggregate_stats(user_id, scope: scope)
    rates = Pipeline.windowed_rates(user_id, scope: scope)
    chart_data = Pipeline.chunks_per_source(user_id, scope: scope)
    search = socket.assigns.pipeline_job_search

    jobs =
      Pipeline.list_jobs(user_id,
        scope: scope,
        search: if(search == "", do: nil, else: search)
      )

    assign(socket,
      pipeline_stats: stats,
      pipeline_rates: rates,
      pipeline_chart_data: chart_data,
      pipeline_jobs: jobs
    )
  end

  defp schedule_pipeline_refresh(socket) do
    Process.send_after(self(), :pipeline_refresh, @refresh_interval_ms)
    socket
  end
end
