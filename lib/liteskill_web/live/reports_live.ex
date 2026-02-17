defmodule LiteskillWeb.ReportsLive do
  @moduledoc """
  Reports event handlers and helpers, rendered within ChatLive's main area.
  """

  use LiteskillWeb, :html

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

  def apply_reports_action(socket, :reports, params) do
    user_id = socket.assigns.current_user.id
    page = parse_page(params["page"])

    %{reports: reports, page: page, total_pages: total_pages, total: total} =
      Liteskill.Reports.list_reports_paginated(user_id, page)

    Phoenix.Component.assign(socket,
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

        Phoenix.Component.assign(socket,
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
        |> Phoenix.LiveView.put_flash(:error, action_error("load report", reason))
        |> Phoenix.LiveView.push_navigate(to: ~p"/reports")
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

  def handle_event("delete_report", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Liteskill.Reports.delete_report(id, user_id) do
      {:ok, _} ->
        {:noreply, reload_reports_list(socket)}

      {:error, reason} ->
        {:noreply,
         Phoenix.LiveView.put_flash(socket, :error, action_error("delete report", reason))}
    end
  end

  def handle_event("leave_report", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Liteskill.Reports.leave_report(id, user_id) do
      {:ok, _} ->
        {:noreply, reload_reports_list(socket)}

      {:error, reason} ->
        {:noreply,
         Phoenix.LiveView.put_flash(socket, :error, action_error("leave report", reason))}
    end
  end

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

  def handle_event("report_edit_mode", _params, socket) do
    {:noreply,
     socket
     |> Phoenix.Component.assign(report_mode: :edit, editing_section_id: nil)
     |> reload_report()}
  end

  def handle_event("report_view_mode", _params, socket) do
    {:noreply,
     socket
     |> Phoenix.Component.assign(report_mode: :view, editing_section_id: nil)
     |> reload_report()}
  end

  def handle_event("edit_section", %{"section-id" => section_id}, socket) do
    {:noreply, Phoenix.Component.assign(socket, editing_section_id: section_id)}
  end

  def handle_event("cancel_edit_section", _params, socket) do
    {:noreply, Phoenix.Component.assign(socket, editing_section_id: nil)}
  end

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
        {:noreply, socket |> Phoenix.Component.assign(editing_section_id: nil) |> reload_report()}

      {:error, _reason} ->
        {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Failed to update section")}
    end
  end

  # --- Wiki Export Events ---

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
          {:noreply,
           socket
           |> Phoenix.Component.assign(show_wiki_export_modal: false)
           |> Phoenix.LiveView.put_flash(:info, "Report exported to wiki")
           |> Phoenix.LiveView.push_navigate(to: ~p"/wiki/#{doc.id}")}

        {:error, reason} ->
          {:noreply,
           Phoenix.LiveView.put_flash(
             socket,
             :error,
             action_error("export report to wiki", reason)
           )}
      end
    end
  end

  # --- Helpers ---

  defp reload_reports_list(socket) do
    user_id = socket.assigns.current_user.id
    page = socket.assigns.reports_page

    %{reports: reports, page: page, total_pages: total_pages, total: total} =
      Liteskill.Reports.list_reports_paginated(user_id, page)

    Phoenix.Component.assign(socket,
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

        Phoenix.Component.assign(socket,
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
