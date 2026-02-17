defmodule Liteskill.BuiltinTools.Wiki do
  @moduledoc """
  Built-in tool suite for reading and writing wiki spaces and articles.

  Provides two tools:
  - `wiki__read` — discovery, browsing, reading, and search
  - `wiki__write` — batch create/update/delete operations
  """

  @behaviour Liteskill.BuiltinTools

  alias Liteskill.Authorization
  alias Liteskill.DataSources

  @impl true
  def id, do: "wiki"

  @impl true
  def name, do: "Wiki"

  @impl true
  def description, do: "Read and write wiki spaces and articles"

  @impl true
  def list_tools do
    [
      %{
        "name" => "wiki__read",
        "description" =>
          "Read wiki content. Modes: " <>
            "\"spaces\" lists accessible spaces with role and article count; " <>
            "\"tree\" returns the article tree for a space; " <>
            "\"articles\" reads article content by IDs (with optional line ranges); " <>
            "\"search\" performs full-text search across accessible wiki content.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "mode" => %{
              "type" => "string",
              "enum" => ["spaces", "tree", "articles", "search"],
              "description" => "The read operation mode"
            },
            "space_id" => %{
              "type" => "string",
              "description" => "Space UUID (required for tree mode, optional for search)"
            },
            "ids" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "Array of article UUIDs (required for articles mode)"
            },
            "ranges" => %{
              "type" => "object",
              "description" =>
                "Line ranges per article ID, e.g. {\"<id>\": {\"start\": 1, \"end\": 50}}"
            },
            "query" => %{
              "type" => "string",
              "description" => "Search string (required for search mode)"
            },
            "page" => %{
              "type" => "integer",
              "description" => "Page number for search results (default 1)"
            }
          },
          "required" => ["mode"]
        }
      },
      %{
        "name" => "wiki__write",
        "description" =>
          "Write wiki content. Takes an array of actions that execute independently. " <>
            "Supported actions: " <>
            "\"create_space\" (requires title, optional content/description); " <>
            "\"create_article\" (requires parent_id and title, optional content); " <>
            "\"update\" (requires id, optional title/content); " <>
            "\"delete\" (requires id). " <>
            "Each action returns its own result — successes commit, failures return errors.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "actions" => %{
              "type" => "array",
              "description" => "Array of write actions to perform",
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "action" => %{
                    "type" => "string",
                    "enum" => ["create_space", "create_article", "update", "delete"],
                    "description" => "The write action to perform"
                  },
                  "id" => %{
                    "type" => "string",
                    "description" => "Article UUID (required for update/delete)"
                  },
                  "parent_id" => %{
                    "type" => "string",
                    "description" => "Parent article/space UUID (required for create_article)"
                  },
                  "title" => %{
                    "type" => "string",
                    "description" => "Title (required for create_space/create_article)"
                  },
                  "content" => %{
                    "type" => "string",
                    "description" => "Content body (optional)"
                  },
                  "description" => %{
                    "type" => "string",
                    "description" => "Space description (optional, for create_space)"
                  }
                },
                "required" => ["action"]
              }
            }
          },
          "required" => ["actions"]
        }
      }
    ]
  end

  @impl true
  def call_tool(tool_name, input, context) do
    user_id = Keyword.fetch!(context, :user_id)

    case tool_name do
      "wiki__read" -> do_read(user_id, input)
      "wiki__write" -> do_write(user_id, input)
      _ -> {:error, "Unknown tool: #{tool_name}"}
    end
    |> wrap_result()
  end

  # --- Read Operations ---

  defp do_read(user_id, %{"mode" => "spaces"}) do
    %{documents: docs} =
      DataSources.list_documents_paginated("builtin:wiki", user_id,
        parent_id: nil,
        page_size: 100
      )

    spaces =
      Enum.map(docs, fn doc ->
        role =
          case Authorization.get_role("wiki_space", doc.id, user_id) do
            {:ok, r} ->
              r

            # coveralls-ignore-start
            _ ->
              "owner"
              # coveralls-ignore-stop
          end

        child_count =
          DataSources.list_documents_paginated("builtin:wiki", user_id,
            parent_id: doc.id,
            page_size: 1
          ).total

        %{
          "id" => doc.id,
          "title" => doc.title,
          "role" => role,
          "article_count" => child_count,
          "updated_at" => DateTime.to_iso8601(doc.updated_at)
        }
      end)

    {:ok, %{"spaces" => spaces}}
  end

  defp do_read(user_id, %{"mode" => "tree", "space_id" => space_id}) do
    case DataSources.get_document(space_id, user_id) do
      {:ok, space} ->
        tree = DataSources.space_tree("builtin:wiki", space_id, user_id)

        {:ok,
         %{
           "space" => %{"id" => space.id, "title" => space.title},
           "articles" => format_tree(tree)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_read(_user_id, %{"mode" => "tree"}), do: {:error, "Missing required field: space_id"}

  defp do_read(user_id, %{"mode" => "articles", "ids" => ids} = input) when is_list(ids) do
    ranges = Map.get(input, "ranges", %{})

    articles =
      Enum.map(ids, fn id ->
        case DataSources.get_document(id, user_id) do
          {:ok, doc} ->
            format_article(doc, Map.get(ranges, id))

          {:error, reason} ->
            %{"id" => id, "error" => to_string(reason)}
        end
      end)

    {:ok, %{"articles" => articles}}
  end

  defp do_read(_user_id, %{"mode" => "articles"}), do: {:error, "Missing required field: ids"}

  defp do_read(user_id, %{"mode" => "search", "query" => query} = input) do
    page = Map.get(input, "page", 1)
    space_id = Map.get(input, "space_id")

    opts = [search: query, page: page]
    opts = if space_id, do: Keyword.put(opts, :parent_id, space_id), else: opts

    %{documents: docs, page: page, total: total} =
      DataSources.list_documents_paginated("builtin:wiki", user_id, opts)

    results =
      Enum.map(docs, fn doc ->
        snippet =
          if doc.content do
            doc.content |> String.slice(0, 200)
          else
            ""
          end

        %{
          "id" => doc.id,
          "title" => doc.title,
          "snippet" => snippet,
          "space_id" => doc.source_ref
        }
      end)

    {:ok, %{"results" => results, "page" => page, "total" => total}}
  end

  defp do_read(_user_id, %{"mode" => "search"}), do: {:error, "Missing required field: query"}

  defp do_read(_user_id, _input), do: {:error, "Missing or invalid mode"}

  # --- Write Operations ---

  defp do_write(user_id, %{"actions" => actions}) when is_list(actions) do
    results = Enum.map(actions, &execute_action(&1, user_id))
    {:ok, %{"results" => results}}
  end

  defp do_write(_user_id, _input), do: {:error, "Missing required field: actions"}

  defp execute_action(%{"action" => "create_space", "title" => title} = action, user_id) do
    with :ok <- Liteskill.Rbac.authorize(user_id, "wiki_spaces:create") do
      attrs = %{title: title}
      attrs = if action["content"], do: Map.put(attrs, :content, action["content"]), else: attrs

      attrs =
        if action["description"],
          do: Map.put(attrs, :description, action["description"]),
          else: attrs

      case DataSources.create_document("builtin:wiki", attrs, user_id) do
        {:ok, doc} ->
          %{"action" => "create_space", "status" => "ok", "id" => doc.id, "title" => doc.title}

        {:error, reason} ->
          %{"action" => "create_space", "status" => "error", "error" => format_error(reason)}
      end
    else
      {:error, reason} ->
        %{"action" => "create_space", "status" => "error", "error" => format_error(reason)}
    end
  end

  defp execute_action(%{"action" => "create_space"}, _user_id) do
    %{"action" => "create_space", "status" => "error", "error" => "missing title"}
  end

  defp execute_action(
         %{"action" => "create_article", "parent_id" => parent_id, "title" => title} = action,
         user_id
       ) do
    attrs = %{title: title}
    attrs = if action["content"], do: Map.put(attrs, :content, action["content"]), else: attrs

    case DataSources.create_child_document("builtin:wiki", parent_id, attrs, user_id) do
      {:ok, doc} ->
        %{
          "action" => "create_article",
          "status" => "ok",
          "id" => doc.id,
          "title" => doc.title
        }

      {:error, reason} ->
        %{"action" => "create_article", "status" => "error", "error" => format_error(reason)}
    end
  end

  defp execute_action(%{"action" => "create_article"}, _user_id) do
    %{
      "action" => "create_article",
      "status" => "error",
      "error" => "missing parent_id or title"
    }
  end

  defp execute_action(%{"action" => "update", "id" => id} = action, user_id) do
    attrs = %{}
    attrs = if action["title"], do: Map.put(attrs, :title, action["title"]), else: attrs
    attrs = if action["content"], do: Map.put(attrs, :content, action["content"]), else: attrs

    case DataSources.update_document(id, attrs, user_id) do
      {:ok, doc} ->
        %{"action" => "update", "status" => "ok", "id" => doc.id, "title" => doc.title}

      {:error, reason} ->
        %{"action" => "update", "status" => "error", "error" => format_error(reason)}
    end
  end

  defp execute_action(%{"action" => "update"}, _user_id) do
    %{"action" => "update", "status" => "error", "error" => "missing id"}
  end

  defp execute_action(%{"action" => "delete", "id" => id}, user_id) do
    case DataSources.delete_document(id, user_id) do
      {:ok, _doc} ->
        %{"action" => "delete", "status" => "ok", "id" => id}

      {:error, reason} ->
        %{"action" => "delete", "status" => "error", "error" => format_error(reason)}
    end
  end

  defp execute_action(%{"action" => "delete"}, _user_id) do
    %{"action" => "delete", "status" => "error", "error" => "missing id"}
  end

  defp execute_action(%{"action" => action}, _user_id) do
    %{"action" => action, "status" => "error", "error" => "unknown action"}
  end

  # coveralls-ignore-start
  defp execute_action(_action, _user_id) do
    %{"action" => "unknown", "status" => "error", "error" => "missing action field"}
  end

  # coveralls-ignore-stop

  # --- Helpers ---

  defp format_tree(nodes) do
    Enum.map(nodes, fn %{document: doc, children: children} ->
      %{
        "id" => doc.id,
        "title" => doc.title,
        "slug" => doc.slug,
        "children" => format_tree(children)
      }
    end)
  end

  defp format_article(doc, nil) do
    content = doc.content || ""
    lines = String.split(content, "\n")

    %{
      "id" => doc.id,
      "title" => doc.title,
      "content" => content,
      "total_lines" => length(lines)
    }
  end

  defp format_article(doc, %{"start" => start_line, "end" => end_line}) do
    content = doc.content || ""
    lines = String.split(content, "\n")
    total = length(lines)

    # 1-indexed, clamp to bounds
    start_idx = max(start_line - 1, 0)
    end_idx = min(end_line, total)

    sliced =
      lines
      |> Enum.slice(start_idx, end_idx - start_idx)
      |> Enum.with_index(start_line)
      |> Enum.map_join("\n", fn {line, num} -> "#{num}: #{line}" end)

    %{
      "id" => doc.id,
      "title" => doc.title,
      "content" => sliced,
      "total_lines" => total,
      "range" => [start_line, end_line]
    }
  end

  # If range exists but is malformed, fall back to full content
  defp format_article(doc, _range), do: format_article(doc, nil)

  defp format_error(reason), do: LiteskillWeb.ErrorHelpers.humanize_error(reason)

  # coveralls-ignore-start
  defp wrap_result({:ok, text}) when is_binary(text) do
    {:ok, %{"content" => [%{"type" => "text", "text" => text}]}}
  end

  # coveralls-ignore-stop

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
