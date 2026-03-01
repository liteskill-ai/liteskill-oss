defmodule Liteskill.BuiltinTools.Reports do
  @moduledoc """
  Built-in tool suite for managing reports.

  Provides tools for creating, reading, updating, and commenting on
  structured reports with infinitely-nesting sections.
  """

  @behaviour Liteskill.BuiltinTools

  alias Liteskill.Reports

  @impl true
  def id, do: "reports"

  @impl true
  def name, do: "Reports"

  @impl true
  def description, do: "Create and manage structured reports with nested sections"

  @impl true
  def list_tools do
    [
      %{
        "name" => "reports__create",
        "description" => "Create a new report. Returns the report ID and title.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "title" => %{"type" => "string", "description" => "The title of the report"}
          },
          "required" => ["title"]
        }
      },
      %{
        "name" => "reports__list",
        "description" => "List all reports the user has access to (owned or shared).",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{}
        }
      },
      %{
        "name" => "reports__get",
        "description" =>
          "Get a report rendered as markdown. The report title is the first line as a # heading. " <>
            "Sections are rendered as ## headings at appropriate depth. " <>
            "Section comments (if any) appear as blockquotes with author type, status, and ID.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "report_id" => %{"type" => "string", "description" => "The report UUID"}
          },
          "required" => ["report_id"]
        }
      },
      %{
        "name" => "reports__modify_sections",
        "description" =>
          "Modify sections in a report. Supports upsert (create/update), " <>
            "delete, and move (reorder) actions in a single call. " <>
            "Actions execute in order within a transaction. " <>
            "Section paths use ' > ' as separator for nesting depth. " <>
            "For example, 'Introduction' is a top-level section (# Introduction), " <>
            "'Findings > Key Points' is a subsection (## Key Points under # Findings). " <>
            "Intermediate sections are auto-created on upsert if they don't exist.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "report_id" => %{"type" => "string", "description" => "The report UUID"},
            "actions" => %{
              "type" => "array",
              "description" => "Array of actions to perform on sections",
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "action" => %{
                    "type" => "string",
                    "enum" => ["upsert", "delete", "move"],
                    "description" => "The action to perform"
                  },
                  "path" => %{
                    "type" => "string",
                    "description" => "Section path using ' > ' separator. E.g. 'Findings > Key Points'"
                  },
                  "content" => %{
                    "type" => "string",
                    "description" => "Text content for the section body (required for upsert)"
                  },
                  "position" => %{
                    "type" => "integer",
                    "description" => "Target 0-based position among siblings (required for move)"
                  }
                },
                "required" => ["action", "path"]
              }
            }
          },
          "required" => ["report_id", "actions"]
        }
      },
      %{
        "name" => "reports__comment",
        "description" =>
          "Manage comments on a report. Supports 'add' (add an agent comment) " <>
            "and 'resolve' (mark a comment as addressed) actions. " <>
            "Actions execute in order within a transaction. " <>
            "For 'add': provide section path and comment body. Omit path (or use empty string) " <>
            "to add a report-level comment not tied to any section. " <>
            "For 'resolve': provide comment_id and body (your reply explaining how you addressed " <>
            "the comment). The body becomes a reply under the original comment.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "report_id" => %{"type" => "string", "description" => "The report UUID"},
            "actions" => %{
              "type" => "array",
              "description" => "Array of comment actions to perform",
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "action" => %{
                    "type" => "string",
                    "enum" => ["add", "resolve"],
                    "description" => "The action to perform"
                  },
                  "path" => %{
                    "type" => "string",
                    "description" => "Section path using ' > ' separator (required for 'add')"
                  },
                  "body" => %{
                    "type" => "string",
                    "description" => "Comment text (required for 'add')"
                  },
                  "comment_id" => %{
                    "type" => "string",
                    "description" => "UUID of the comment to resolve (required for 'resolve')"
                  }
                },
                "required" => ["action"]
              }
            }
          },
          "required" => ["report_id", "actions"]
        }
      },
      %{
        "name" => "reports__delete",
        "description" => "Delete a report and all its sections. Only the report owner can delete.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "report_id" => %{"type" => "string", "description" => "The report UUID"}
          },
          "required" => ["report_id"]
        }
      }
    ]
  end

  @impl true
  def call_tool(tool_name, input, context) do
    user_id = Keyword.fetch!(context, :user_id)

    case_result =
      case tool_name do
        "reports__create" -> do_create(user_id, input, context)
        "reports__list" -> do_list(user_id)
        "reports__get" -> do_get(user_id, input)
        "reports__modify_sections" -> do_modify_sections(user_id, input)
        "reports__comment" -> do_comment(user_id, input)
        "reports__delete" -> do_delete(user_id, input)
        _ -> {:error, "Unknown tool: #{tool_name}"}
      end

    wrap_result(case_result)
  end

  defp do_create(user_id, %{"title" => title}, context) do
    opts = if run_id = Keyword.get(context, :run_id), do: [run_id: run_id], else: []

    case Reports.create_report(user_id, title, opts) do
      {:ok, report} ->
        {:ok, %{"id" => report.id, "title" => report.title}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_create(_user_id, _input, _context), do: {:error, "Missing required field: title"}

  defp do_list(user_id) do
    reports = Reports.list_reports(user_id)

    {:ok,
     %{
       "reports" =>
         Enum.map(reports, fn r ->
           %{
             "id" => r.id,
             "title" => r.title,
             "created_at" => DateTime.to_iso8601(r.inserted_at)
           }
         end)
     }}
  end

  defp do_get(user_id, %{"report_id" => report_id}) do
    case Reports.get_report(report_id, user_id) do
      {:ok, report} ->
        markdown = Reports.render_markdown(report, start_depth: 2)
        {:ok, String.trim("# #{report.title}\n\n#{markdown}")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_get(_user_id, _input), do: {:error, "Missing required field: report_id"}

  defp do_modify_sections(user_id, %{"report_id" => report_id, "actions" => actions}) when is_list(actions) do
    case Reports.modify_sections(report_id, user_id, actions) do
      {:ok, results} ->
        {:ok, %{"results" => Enum.map(results, &Map.new(&1, fn {k, v} -> {to_string(k), v} end))}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_modify_sections(_user_id, _input), do: {:error, "Missing required fields: report_id, actions"}

  defp do_comment(user_id, %{"report_id" => report_id, "actions" => actions}) when is_list(actions) do
    case Reports.manage_comments(report_id, user_id, actions) do
      {:ok, results} ->
        {:ok, %{"results" => Enum.map(results, &Map.new(&1, fn {k, v} -> {to_string(k), v} end))}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_comment(_user_id, _input), do: {:error, "Missing required fields: report_id, actions"}

  defp do_delete(user_id, %{"report_id" => report_id}) do
    case Reports.delete_report(report_id, user_id) do
      {:ok, _report} -> {:ok, %{"deleted" => true}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_delete(_user_id, _input), do: {:error, "Missing required field: report_id"}

  defp wrap_result({:ok, text}) when is_binary(text) do
    {:ok, %{"content" => [%{"type" => "text", "text" => text}]}}
  end

  defp wrap_result({:ok, data}) do
    {:ok, %{"content" => [%{"type" => "text", "text" => Jason.encode!(data)}]}}
  end

  defp wrap_result({:error, reason}) do
    text =
      case reason do
        atom when is_atom(atom) ->
          Atom.to_string(atom)

        str when is_binary(str) ->
          str

        # coveralls-ignore-start
        _ ->
          "unknown error"
          # coveralls-ignore-stop
      end

    {:ok, %{"content" => [%{"type" => "text", "text" => Jason.encode!(%{"error" => text})}]}}
  end
end
