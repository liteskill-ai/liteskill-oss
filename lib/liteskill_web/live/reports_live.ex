defmodule LiteskillWeb.ReportsLive do
  @moduledoc """
  Reports event handlers and helpers, rendered within ChatLive's main area.
  """

  use LiteskillWeb, :live_view

  alias Liteskill.Chat
  alias LiteskillWeb.ChatComponents
  alias LiteskillWeb.Layouts
  alias LiteskillWeb.ReportComponents
  alias LiteskillWeb.SharingComponents
  alias LiteskillWeb.SharingLive
  alias LiteskillWeb.WikiComponents

  @reports_actions [:reports, :report_show]

  def reports_action?(action), do: action in @reports_actions

  def reports_assigns do
    [
      reports: [],
      reports_page: 1,
      reports_total_pages: 1,
      reports_total: 0,
      report: nil,
      report_markdown: "",
      section_tree: [],
      report_comments: [],
      editing_section_id: nil,
      report_mode: :view,
      show_wiki_export_modal: false,
      wiki_export_title: "",
      wiki_export_parent_id: nil,
      wiki_export_tree: []
    ]
  end

  # --- LiveView callbacks ---

  @impl true
  def mount(_params, _session, socket) do
    conversations = Chat.list_conversations(socket.assigns.current_user.id)

    {:ok,
     socket
     |> assign(reports_assigns())
     |> assign(
       conversations: conversations,
       conversation: nil,
       sidebar_open: true,
       has_admin_access: Liteskill.Rbac.has_any_admin_permission?(socket.assigns.current_user.id),
       single_user_mode: Liteskill.SingleUser.enabled?(),
       # Sharing modal state
       show_sharing: false,
       sharing_entity_type: nil,
       sharing_entity_id: nil,
       sharing_acls: [],
       sharing_user_search_results: [],
       sharing_user_search_query: "",
       sharing_groups: [],
       sharing_error: nil
     ), layout: {Layouts, :chat}}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, action, params) when action in @reports_actions do
    apply_reports_action(socket, action, params)
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
        <%= if @live_action == :reports do %>
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
      </main>
    </div>
    """
  end

  def apply_reports_action(socket, :reports, params) do
    user_id = socket.assigns.current_user.id
    page = parse_page(params["page"])

    %{reports: reports, page: page, total_pages: total_pages, total: total} =
      Liteskill.Reports.list_reports_paginated(user_id, page)

    assign(socket,
      conversation: nil,
      messages: [],
      streaming: false,
      stream_content: "",
      pending_tool_calls: [],
      reports: reports,
      reports_page: page,
      reports_total_pages: total_pages,
      reports_total: total,
      page_title: "Reports"
    )
  end

  def apply_reports_action(socket, :report_show, %{"report_id" => report_id}) do
    user_id = socket.assigns.current_user.id

    case Liteskill.Reports.get_report(report_id, user_id) do
      {:ok, report} ->
        markdown = Liteskill.Reports.render_markdown(report, include_comments: false)
        section_tree = Liteskill.Reports.section_tree(report)

        report_comments =
          case Liteskill.Reports.get_report_comments(report_id, user_id) do
            {:ok, comments} -> comments
            _ -> []
          end

        assign(socket,
          conversation: nil,
          messages: [],
          streaming: false,
          stream_content: "",
          pending_tool_calls: [],
          report: report,
          report_markdown: markdown,
          section_tree: section_tree,
          report_comments: report_comments,
          editing_section_id: nil,
          report_mode: :view,
          page_title: report.title
        )

      {:error, reason} ->
        socket
        |> put_flash(:error, action_error("load report", reason))
        |> push_navigate(to: ~p"/reports")
    end
  end

  defp parse_page(nil), do: 1

  defp parse_page(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} when n >= 1 -> n
      _ -> 1
    end
  end

  # --- Event Handlers (called from ChatLive) ---

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
  def handle_event("delete_report", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Liteskill.Reports.delete_report(id, user_id) do
      {:ok, _} ->
        {:noreply, reload_reports_list(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("delete report", reason))}
    end
  end

  @impl true
  def handle_event("leave_report", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Liteskill.Reports.leave_report(id, user_id) do
      {:ok, _} ->
        {:noreply, reload_reports_list(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("leave report", reason))}
    end
  end

  @impl true
  def handle_event("export_report", _params, socket) do
    report = socket.assigns.report
    markdown = socket.assigns.report_markdown

    filename =
      report.title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> Kernel.<>(".md")

    {:noreply,
     Phoenix.LiveView.push_event(socket, "download_markdown", %{
       filename: filename,
       content: markdown
     })}
  end

  @impl true
  def handle_event("add_section_comment", %{"section_id" => section_id, "body" => body}, socket) do
    body = String.trim(body)

    if body == "" do
      {:noreply, socket}
    else
      user_id = socket.assigns.current_user.id
      Liteskill.Reports.add_comment(section_id, user_id, body, "user")
      {:noreply, reload_report(socket)}
    end
  end

  @impl true
  def handle_event("add_report_comment", %{"body" => body}, socket) do
    body = String.trim(body)

    if body == "" do
      {:noreply, socket}
    else
      user_id = socket.assigns.current_user.id
      report_id = socket.assigns.report.id
      Liteskill.Reports.add_report_comment(report_id, user_id, body, "user")
      {:noreply, reload_report(socket)}
    end
  end

  @impl true
  def handle_event("reply_to_comment", %{"comment_id" => comment_id, "body" => body}, socket) do
    body = String.trim(body)

    if body == "" do
      {:noreply, socket}
    else
      user_id = socket.assigns.current_user.id
      Liteskill.Reports.reply_to_comment(comment_id, user_id, body, "user")
      {:noreply, reload_report(socket)}
    end
  end

  @impl true
  def handle_event("report_edit_mode", _params, socket) do
    {:noreply,
     socket
     |> assign(report_mode: :edit, editing_section_id: nil)
     |> reload_report()}
  end

  @impl true
  def handle_event("report_view_mode", _params, socket) do
    {:noreply,
     socket
     |> assign(report_mode: :view, editing_section_id: nil)
     |> reload_report()}
  end

  @impl true
  def handle_event("edit_section", %{"section-id" => section_id}, socket) do
    {:noreply, assign(socket, editing_section_id: section_id)}
  end

  @impl true
  def handle_event("cancel_edit_section", _params, socket) do
    {:noreply, assign(socket, editing_section_id: nil)}
  end

  @impl true
  def handle_event("save_section", params, socket) do
    section_id = params["section-id"]
    user_id = socket.assigns.current_user.id

    attrs =
      %{}
      |> then(fn a ->
        if params["content"], do: Map.put(a, :content, params["content"]), else: a
      end)
      |> then(fn a ->
        title = params["title"]

        if is_binary(title) && String.trim(title) != "",
          do: Map.put(a, :title, String.trim(title)),
          else: a
      end)

    case Liteskill.Reports.update_section_content(section_id, user_id, attrs) do
      {:ok, _section} ->
        {:noreply, socket |> assign(editing_section_id: nil) |> reload_report()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update section")}
    end
  end

  # --- Wiki Export Events ---

  @impl true
  def handle_event("open_wiki_export_modal", _params, socket) do
    user_id = socket.assigns.current_user.id
    tree = Liteskill.DataSources.document_tree("builtin:wiki", user_id)

    {:noreply,
     assign(socket,
       show_wiki_export_modal: true,
       wiki_export_title: socket.assigns.report.title,
       wiki_export_parent_id: nil,
       wiki_export_tree: tree
     )}
  end

  @impl true
  def handle_event("close_wiki_export_modal", _params, socket) do
    {:noreply, assign(socket, show_wiki_export_modal: false)}
  end

  @impl true
  def handle_event("confirm_wiki_export", %{"title" => title, "parent_id" => parent_id}, socket) do
    if parent_id == "" do
      {:noreply, put_flash(socket, :error, "Please select a space for the wiki page")}
    else
      user_id = socket.assigns.current_user.id
      report = socket.assigns.report

      case Liteskill.DataSources.export_report_to_wiki(report.id, user_id,
             title: title,
             parent_id: parent_id
           ) do
        {:ok, doc} ->
          {:noreply,
           socket
           |> assign(show_wiki_export_modal: false)
           |> put_flash(:info, "Report exported to wiki")
           |> push_navigate(to: ~p"/wiki/#{doc.id}")}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             action_error("export report to wiki", reason)
           )}
      end
    end
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

        case Chat.send_message(conversation.id, user_id, content) do
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
  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Helpers ---

  defp reload_reports_list(socket) do
    user_id = socket.assigns.current_user.id
    page = socket.assigns.reports_page

    %{reports: reports, page: page, total_pages: total_pages, total: total} =
      Liteskill.Reports.list_reports_paginated(user_id, page)

    assign(socket,
      reports: reports,
      reports_page: page,
      reports_total_pages: total_pages,
      reports_total: total
    )
  end

  def reload_report(socket) do
    report = socket.assigns.report
    user_id = socket.assigns.current_user.id

    case Liteskill.Reports.get_report(report.id, user_id) do
      {:ok, report} ->
        section_tree = Liteskill.Reports.section_tree(report)

        report_comments =
          case Liteskill.Reports.get_report_comments(report.id, user_id) do
            {:ok, comments} -> comments
            _ -> []
          end

        include_comments = socket.assigns[:report_mode] != :view
        markdown = Liteskill.Reports.render_markdown(report, include_comments: include_comments)

        assign(socket,
          report: report,
          section_tree: section_tree,
          report_comments: report_comments,
          report_markdown: markdown
        )

      # coveralls-ignore-start
      {:error, _} ->
        socket
        # coveralls-ignore-stop
    end
  end
end
