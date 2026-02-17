defmodule Liteskill.Reports do
  use Boundary,
    top_level?: true,
    deps: [Liteskill.Accounts, Liteskill.Authorization, Liteskill.Rbac],
    exports: [Report, ReportSection, SectionComment]

  @moduledoc """
  Context for managing reports and their nested sections.

  Reports are structured documents with infinitely-nesting sections
  that render as markdown with #, ##, ### etc. headers.
  """

  alias Liteskill.Accounts.User
  alias Liteskill.Authorization
  alias Liteskill.Reports.{Report, ReportSection, SectionComment}
  alias Liteskill.Repo

  import Ecto.Query

  @doc "System prompt for the LLM agent that addresses report comments."
  def address_comments_system_prompt do
    "You are a report editing assistant. You have access to the Reports tools. " <>
      "When asked to address comments, use reports__get to read the report and see all comments. " <>
      "For each [OPEN] comment, make meaningful section updates using reports__modify_sections, " <>
      "then mark the comment as addressed using reports__comment with the \"resolve\" action. " <>
      "If you are unsure how to address a comment, add an agent comment with your question " <>
      "rather than making incorrect changes."
  end

  # --- Reports CRUD ---

  def create_report(user_id, title, opts \\ []) do
    with :ok <- Liteskill.Rbac.authorize(user_id, "reports:create") do
      run_id = Keyword.get(opts, :run_id)

      attrs =
        %{title: title, user_id: user_id}
        |> then(fn a -> if run_id, do: Map.put(a, :run_id, run_id), else: a end)

      Repo.transaction(fn ->
        report =
          %Report{}
          |> Report.changeset(attrs)
          |> Repo.insert!()

        {:ok, _} = Authorization.create_owner_acl("report", report.id, user_id)

        report
      end)
    end
  end

  def list_reports(user_id) do
    accessible_ids = Authorization.accessible_entity_ids("report", user_id)

    Report
    |> where([r], r.user_id == ^user_id or r.id in subquery(accessible_ids))
    |> order_by([r], desc: r.updated_at)
    |> Repo.all()
  end

  @reports_per_page 20

  def list_reports_paginated(user_id, page) when is_integer(page) and page >= 1 do
    accessible_ids = Authorization.accessible_entity_ids("report", user_id)

    base_query =
      Report
      |> where([r], r.user_id == ^user_id or r.id in subquery(accessible_ids))

    total = Repo.aggregate(base_query, :count)
    total_pages = max(ceil(total / @reports_per_page), 1)

    reports =
      base_query
      |> order_by([r], desc: r.updated_at)
      |> limit(@reports_per_page)
      |> offset(^(@reports_per_page * (page - 1)))
      |> Repo.all()
      |> Repo.preload([:user, run: :team_definition])

    %{reports: reports, page: page, total_pages: total_pages, total: total}
  end

  def get_report(report_id, user_id) do
    case Repo.get(Report, report_id) do
      nil ->
        {:error, :not_found}

      report ->
        if has_access?(report, user_id) do
          {:ok, Repo.preload(report, sections: from(s in ReportSection, order_by: s.position))}
        else
          {:error, :not_found}
        end
    end
  end

  def delete_report(report_id, user_id) do
    with {:ok, report} <- authorize_owner(report_id, user_id) do
      Repo.delete(report)
    end
  end

  # --- Section Management ---

  def upsert_section(report_id, user_id, path, content) do
    with {:ok, report} <- authorize_access(report_id, user_id) do
      parts = parse_path(path)

      if parts == [] do
        {:error, :invalid_path}
      else
        Repo.transaction(fn ->
          walk_and_upsert(report.id, nil, parts, content)
        end)
      end
    end
  end

  def upsert_sections(report_id, user_id, sections) when is_list(sections) do
    with {:ok, report} <- authorize_access(report_id, user_id) do
      parsed =
        Enum.reduce_while(sections, {:ok, []}, fn section, {:ok, acc} ->
          path = section[:path] || section["path"] || ""
          content = section[:content] || section["content"] || ""
          parts = parse_path(path)

          if parts == [] do
            {:halt, {:error, :invalid_path}}
          else
            {:cont, {:ok, [{parts, content} | acc]}}
          end
        end)

      case parsed do
        {:error, reason} ->
          {:error, reason}

        {:ok, entries} ->
          Repo.transaction(fn ->
            entries
            |> Enum.reverse()
            |> Enum.map(fn {parts, content} ->
              section = walk_and_upsert(report.id, nil, parts, content)
              %{section_id: section.id, path: Enum.join(parts, " > ")}
            end)
          end)
      end
    end
  end

  def modify_sections(report_id, user_id, actions) when is_list(actions) do
    with {:ok, report} <- authorize_access(report_id, user_id) do
      case parse_actions(actions) do
        {:error, reason} ->
          {:error, reason}

        {:ok, parsed_actions} ->
          Repo.transaction(fn ->
            parsed_actions
            |> Enum.reverse()
            |> Enum.map(fn action -> execute_action(report.id, action) end)
          end)
      end
    end
  end

  defp parse_actions(actions) do
    Enum.reduce_while(actions, {:ok, []}, fn action, {:ok, acc} ->
      action_type = action["action"] || action[:action]
      path_str = action["path"] || action[:path] || ""
      parts = parse_path(path_str)

      case action_type do
        "upsert" ->
          if parts == [] do
            {:halt, {:error, :invalid_path}}
          else
            content = action["content"] || action[:content] || ""
            {:cont, {:ok, [{:upsert, parts, content} | acc]}}
          end

        "delete" ->
          if parts == [] do
            {:halt, {:error, :invalid_path}}
          else
            {:cont, {:ok, [{:delete, parts} | acc]}}
          end

        "move" ->
          position = action["position"] || action[:position]

          cond do
            parts == [] -> {:halt, {:error, :invalid_path}}
            not is_integer(position) -> {:halt, {:error, :invalid_position}}
            true -> {:cont, {:ok, [{:move, parts, position} | acc]}}
          end

        nil ->
          {:halt, {:error, :missing_action}}

        _ ->
          {:halt, {:error, :unknown_action}}
      end
    end)
  end

  defp execute_action(report_id, {:upsert, parts, content}) do
    section = walk_and_upsert(report_id, nil, parts, content)
    %{action: "upsert", path: Enum.join(parts, " > "), section_id: section.id}
  end

  defp execute_action(report_id, {:delete, parts}) do
    case find_section_by_path(report_id, parts) do
      nil -> Repo.rollback(:section_not_found)
      section -> Repo.delete!(section)
    end

    %{action: "delete", path: Enum.join(parts, " > ")}
  end

  defp execute_action(report_id, {:move, parts, position}) do
    case find_section_by_path(report_id, parts) do
      nil ->
        Repo.rollback(:section_not_found)

      section ->
        execute_move(report_id, section, position)
        %{action: "move", path: Enum.join(parts, " > "), position: position}
    end
  end

  defp find_section_by_path(report_id, parts) do
    Enum.reduce_while(parts, {nil, nil}, fn title, {parent_id, _section} ->
      case find_section(report_id, parent_id, title) do
        nil -> {:halt, {parent_id, nil}}
        section -> {:cont, {section.id, section}}
      end
    end)
    |> elem(1)
  end

  defp execute_move(report_id, section, target_position) do
    siblings_query =
      from(s in ReportSection,
        where: s.report_id == ^report_id,
        order_by: s.position
      )

    siblings_query =
      if section.parent_section_id do
        where(siblings_query, [s], s.parent_section_id == ^section.parent_section_id)
      else
        where(siblings_query, [s], is_nil(s.parent_section_id))
      end

    siblings = Repo.all(siblings_query)
    others = Enum.reject(siblings, &(&1.id == section.id))
    clamped = min(max(target_position, 0), length(others))
    {before, after_list} = Enum.split(others, clamped)
    reordered = before ++ [section] ++ after_list

    Enum.with_index(reordered, fn s, idx ->
      if s.position != idx do
        s |> ReportSection.changeset(%{position: idx}) |> Repo.update!()
      end
    end)
  end

  defp parse_path(path) do
    path
    |> String.split(">")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp walk_and_upsert(report_id, parent_id, [title], content) do
    section = find_section(report_id, parent_id, title)

    case section do
      nil ->
        next_pos = next_position(report_id, parent_id)

        %ReportSection{}
        |> ReportSection.changeset(%{
          report_id: report_id,
          parent_section_id: parent_id,
          title: title,
          content: content,
          position: next_pos
        })
        |> Repo.insert!()

      existing ->
        existing
        |> ReportSection.changeset(%{content: content})
        |> Repo.update!()
    end
  end

  defp walk_and_upsert(report_id, parent_id, [title | rest], content) do
    section = find_or_create_section(report_id, parent_id, title)
    walk_and_upsert(report_id, section.id, rest, content)
  end

  defp find_section(report_id, parent_id, title) do
    query =
      from(s in ReportSection,
        where: s.report_id == ^report_id and s.title == ^title
      )

    query =
      if parent_id do
        where(query, [s], s.parent_section_id == ^parent_id)
      else
        where(query, [s], is_nil(s.parent_section_id))
      end

    Repo.one(query)
  end

  defp find_or_create_section(report_id, parent_id, title) do
    case find_section(report_id, parent_id, title) do
      nil ->
        next_pos = next_position(report_id, parent_id)

        %ReportSection{}
        |> ReportSection.changeset(%{
          report_id: report_id,
          parent_section_id: parent_id,
          title: title,
          position: next_pos
        })
        |> Repo.insert!()

      existing ->
        existing
    end
  end

  defp next_position(report_id, parent_id) do
    query =
      from(s in ReportSection,
        where: s.report_id == ^report_id,
        select: count(s.id)
      )

    query =
      if parent_id do
        where(query, [s], s.parent_section_id == ^parent_id)
      else
        where(query, [s], is_nil(s.parent_section_id))
      end

    Repo.one(query)
  end

  def update_section_content(section_id, user_id, attrs) when is_map(attrs) do
    case Repo.get(ReportSection, section_id) do
      nil ->
        {:error, :not_found}

      section ->
        with {:ok, _report} <- authorize_access(section.report_id, user_id) do
          section
          |> ReportSection.changeset(attrs)
          |> Repo.update()
        end
    end
  end

  def delete_section(section_id, user_id) do
    case Repo.get(ReportSection, section_id) do
      nil ->
        {:error, :not_found}

      section ->
        with {:ok, _report} <- authorize_access(section.report_id, user_id) do
          Repo.delete(section)
        end
    end
  end

  # --- Section Comments ---

  def add_comment(section_id, user_id, body, author_type) do
    with {:ok, section, _report} <- authorize_section_access(section_id, user_id),
         true <- author_type in ["user", "agent"] do
      %SectionComment{}
      |> SectionComment.changeset(%{
        section_id: section.id,
        report_id: section.report_id,
        user_id: user_id,
        body: body,
        author_type: author_type
      })
      |> Repo.insert()
    else
      false -> {:error, :invalid_author_type}
      error -> error
    end
  end

  def resolve_comment(comment_id, user_id, body) do
    case Repo.get(SectionComment, comment_id) do
      nil ->
        {:error, :not_found}

      %SectionComment{section_id: nil} = comment ->
        with {:ok, _report} <- authorize_access(comment.report_id, user_id) do
          resolve_with_reply(comment, user_id, body)
        end

      comment ->
        with {:ok, _section, _report} <- authorize_section_access(comment.section_id, user_id) do
          resolve_with_reply(comment, user_id, body)
        end
    end
  end

  def reply_to_comment(comment_id, user_id, body, author_type) do
    case Repo.get(SectionComment, comment_id) do
      nil ->
        {:error, :not_found}

      parent ->
        with {:ok, _report} <- authorize_access(parent.report_id, user_id),
             true <- author_type in ["user", "agent"] do
          %SectionComment{}
          |> SectionComment.changeset(%{
            parent_comment_id: parent.id,
            report_id: parent.report_id,
            section_id: parent.section_id,
            user_id: user_id,
            body: body,
            author_type: author_type
          })
          |> Repo.insert()
        else
          false -> {:error, :invalid_author_type}
          error -> error
        end
    end
  end

  defp resolve_with_reply(comment, user_id, body) do
    Repo.transaction(fn ->
      {:ok, _reply} =
        %SectionComment{}
        |> SectionComment.changeset(%{
          parent_comment_id: comment.id,
          report_id: comment.report_id,
          section_id: comment.section_id,
          user_id: user_id,
          body: body,
          author_type: "agent"
        })
        |> Repo.insert()

      {:ok, updated} =
        comment
        |> SectionComment.changeset(%{status: "addressed"})
        |> Repo.update()

      updated
    end)
  end

  def list_section_comments(section_id, user_id) do
    with {:ok, _section, _report} <- authorize_section_access(section_id, user_id) do
      comments =
        from(c in SectionComment,
          where: c.section_id == ^section_id,
          order_by: [asc: c.inserted_at]
        )
        |> Repo.all()

      {:ok, comments}
    end
  end

  def get_report_comments(report_id, user_id) do
    with {:ok, _report} <- authorize_access(report_id, user_id) do
      comments =
        from(c in SectionComment,
          where:
            c.report_id == ^report_id and is_nil(c.section_id) and
              is_nil(c.parent_comment_id),
          order_by: [asc: c.inserted_at]
        )
        |> Repo.all()
        |> Repo.preload(replies: from(r in SectionComment, order_by: r.inserted_at))

      {:ok, comments}
    end
  end

  def add_report_comment(report_id, user_id, body, author_type) do
    with {:ok, _report} <- authorize_access(report_id, user_id),
         true <- author_type in ["user", "agent"] do
      %SectionComment{}
      |> SectionComment.changeset(%{
        report_id: report_id,
        user_id: user_id,
        body: body,
        author_type: author_type
      })
      |> Repo.insert()
    else
      false -> {:error, :invalid_author_type}
      error -> error
    end
  end

  def section_tree(%Report{} = report) do
    sections =
      report
      |> Ecto.assoc(:sections)
      |> order_by(:position)
      |> Repo.all()
      |> Repo.preload(
        comments:
          {from(c in SectionComment,
             where: is_nil(c.parent_comment_id),
             order_by: c.inserted_at
           ), replies: from(r in SectionComment, order_by: r.inserted_at)}
      )

    build_tree(sections, nil)
  end

  def manage_comments(report_id, user_id, actions) when is_list(actions) do
    with {:ok, _report} <- authorize_access(report_id, user_id) do
      case parse_comment_actions(actions) do
        {:error, reason} ->
          {:error, reason}

        {:ok, parsed_actions} ->
          Repo.transaction(fn ->
            parsed_actions
            |> Enum.reverse()
            |> Enum.map(fn action -> execute_comment_action(report_id, user_id, action) end)
          end)
      end
    end
  end

  defp authorize_section_access(section_id, user_id) do
    case Repo.get(ReportSection, section_id) do
      nil ->
        {:error, :not_found}

      section ->
        case authorize_access(section.report_id, user_id) do
          {:ok, report} -> {:ok, section, report}
          error -> error
        end
    end
  end

  defp parse_comment_actions(actions) do
    Enum.reduce_while(actions, {:ok, []}, fn action, {:ok, acc} ->
      action_type = action["action"] || action[:action]

      case action_type do
        "add" ->
          path_str = action["path"] || action[:path] || ""
          body = action["body"] || action[:body]
          parts = parse_path(path_str)

          cond do
            is_nil(body) or body == "" -> {:halt, {:error, :missing_body}}
            parts == [] -> {:cont, {:ok, [{:add_report, body} | acc]}}
            true -> {:cont, {:ok, [{:add, parts, body} | acc]}}
          end

        "resolve" ->
          comment_id = action["comment_id"] || action[:comment_id]
          body = action["body"] || action[:body]

          cond do
            is_nil(comment_id) -> {:halt, {:error, :missing_comment_id}}
            is_nil(body) or body == "" -> {:halt, {:error, :missing_body}}
            true -> {:cont, {:ok, [{:resolve, comment_id, body} | acc]}}
          end

        nil ->
          {:halt, {:error, :missing_action}}

        _ ->
          {:halt, {:error, :unknown_action}}
      end
    end)
  end

  defp execute_comment_action(report_id, user_id, {:add_report, body}) do
    {:ok, comment} =
      %SectionComment{}
      |> SectionComment.changeset(%{
        report_id: report_id,
        user_id: user_id,
        body: body,
        author_type: "agent"
      })
      |> Repo.insert()

    %{action: "add", path: "", comment_id: comment.id}
  end

  defp execute_comment_action(report_id, user_id, {:add, parts, body}) do
    case find_section_by_path(report_id, parts) do
      nil ->
        Repo.rollback(:section_not_found)

      section ->
        {:ok, comment} =
          %SectionComment{}
          |> SectionComment.changeset(%{
            section_id: section.id,
            report_id: report_id,
            user_id: user_id,
            body: body,
            author_type: "agent"
          })
          |> Repo.insert()

        %{action: "add", path: Enum.join(parts, " > "), comment_id: comment.id}
    end
  end

  defp execute_comment_action(report_id, user_id, {:resolve, comment_id, body}) do
    case Repo.get(SectionComment, comment_id) do
      nil ->
        Repo.rollback(:comment_not_found)

      %SectionComment{status: "addressed"} = comment ->
        %{action: "resolve", comment_id: comment.id, already_addressed: true}

      comment ->
        {:ok, reply} =
          %SectionComment{}
          |> SectionComment.changeset(%{
            parent_comment_id: comment.id,
            report_id: report_id,
            section_id: comment.section_id,
            user_id: user_id,
            body: body,
            author_type: "agent"
          })
          |> Repo.insert()

        {:ok, _} =
          comment
          |> SectionComment.changeset(%{status: "addressed"})
          |> Repo.update()

        %{action: "resolve", comment_id: comment.id, reply_id: reply.id}
    end
  end

  # --- Markdown Rendering ---

  def render_markdown(%Report{} = report, opts \\ []) do
    include_comments = Keyword.get(opts, :include_comments, true)

    report_comments_md =
      if include_comments do
        report_comments =
          from(c in SectionComment,
            where:
              c.report_id == ^report.id and is_nil(c.section_id) and
                is_nil(c.parent_comment_id),
            order_by: c.inserted_at
          )
          |> Repo.all()
          |> Repo.preload(replies: from(r in SectionComment, order_by: r.inserted_at))

        render_comments(report_comments)
      else
        ""
      end

    sections =
      report
      |> Ecto.assoc(:sections)
      |> order_by(:position)
      |> Repo.all()

    sections =
      if include_comments do
        Repo.preload(sections,
          comments:
            {from(c in SectionComment,
               where: is_nil(c.parent_comment_id),
               order_by: c.inserted_at
             ), replies: from(r in SectionComment, order_by: r.inserted_at)}
        )
      else
        sections
      end

    start_depth = Keyword.get(opts, :start_depth, 1)
    tree = build_tree(sections, nil)
    section_md = render_tree(tree, start_depth, include_comments)

    (report_comments_md <> section_md) |> String.trim()
  end

  defp build_tree(sections, parent_id) do
    sections
    |> Enum.filter(&(&1.parent_section_id == parent_id))
    |> Enum.sort_by(& &1.position)
    |> Enum.map(fn section ->
      %{section: section, children: build_tree(sections, section.id)}
    end)
  end

  defp render_tree(nodes, depth, include_comments) do
    Enum.map_join(nodes, "\n", fn %{section: section, children: children} ->
      prefix = String.duplicate("#", depth)
      header = "#{prefix} #{section.title}\n"

      body =
        if section.content && section.content != "" do
          "\n#{section.content}\n"
        else
          ""
        end

      comments =
        if include_comments do
          render_comments(section.comments)
        else
          ""
        end

      child_content = render_tree(children, depth + 1, include_comments)

      header <> body <> comments <> child_content
    end)
  end

  defp render_comments([]), do: ""

  defp render_comments(comments) do
    rendered =
      Enum.map_join(comments, "\n", fn comment ->
        type_label = String.upcase(comment.author_type)
        status_label = if comment.status == "addressed", do: "ADDRESSED", else: "OPEN"

        parent_line =
          "> **[#{type_label}] [#{status_label}] (id:#{comment.id})**: #{comment.body}"

        reply_lines =
          (comment.replies || [])
          |> Enum.map_join("\n", fn reply ->
            reply_type = String.upcase(reply.author_type)
            ">> **[#{reply_type}] (reply)**: #{reply.body}"
          end)

        if reply_lines == "", do: parent_line, else: parent_line <> "\n" <> reply_lines
      end)

    "\n#{rendered}\n"
  end

  # --- ACL Management (delegates to Authorization) ---

  def grant_access(report_id, owner_id, grantee_email, role \\ "member") do
    normalized_role = if role == "member", do: "manager", else: role

    case Repo.get_by(User, email: grantee_email) do
      nil ->
        {:error, :user_not_found}

      grantee ->
        Authorization.grant_access("report", report_id, owner_id, grantee.id, normalized_role)
    end
  end

  def revoke_access(report_id, owner_id, target_user_id) do
    Authorization.revoke_access("report", report_id, owner_id, target_user_id)
  end

  def leave_report(report_id, user_id) do
    Authorization.leave("report", report_id, user_id)
  end

  # --- Authorization Helpers ---

  defp authorize_owner(report_id, user_id) do
    case Repo.get(Report, report_id) do
      nil -> {:error, :not_found}
      %Report{user_id: ^user_id} = report -> {:ok, report}
      _ -> {:error, :forbidden}
    end
  end

  defp authorize_access(report_id, user_id) do
    case Repo.get(Report, report_id) do
      nil ->
        {:error, :not_found}

      report ->
        if has_access?(report, user_id) do
          {:ok, report}
        else
          {:error, :not_found}
        end
    end
  end

  defp has_access?(report, user_id) do
    report.user_id == user_id or
      Authorization.has_access?("report", report.id, user_id)
  end
end
