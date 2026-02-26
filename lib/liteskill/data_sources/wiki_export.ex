defmodule Liteskill.DataSources.WikiExport do
  @moduledoc """
  Exports a wiki space as a ZIP file with markdown pages and a manifest.

  ## ZIP Structure

      manifest.json
      page-slug.md                   # leaf page
      page-with-kids/
        page-with-kids.md            # page content
        children/
          child.md                   # nested pages

  Each `.md` file has YAML-style frontmatter with `title` and `position`.
  """

  alias Liteskill.DataSources

  @doc """
  Exports a wiki space as a ZIP binary.

  Returns `{:ok, {filename, zip_binary}}` or `{:error, reason}`.
  """
  @spec export_space(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, {String.t(), binary()}} | {:error, term()}
  def export_space(space_id, user_id) do
    with {:ok, space_doc} <- DataSources.get_document(space_id, user_id) do
      tree = DataSources.space_tree("builtin:wiki", space_id, user_id)

      manifest =
        Jason.encode!(%{
          version: 1,
          space_title: space_doc.title,
          space_content: space_doc.content || "",
          exported_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        })

      entries = [{~c"manifest.json", manifest} | build_entries(tree, "")]
      filename = "#{space_doc.slug}.zip"

      case :zip.create(~c"#{filename}", entries, [:memory]) do
        {:ok, {_name, zip_binary}} -> {:ok, {filename, zip_binary}}
        # coveralls-ignore-next-line
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Recursively builds ZIP entries from a tree of documents.
  """
  @spec build_entries([map()], String.t()) :: [{charlist(), binary()}]
  def build_entries(nodes, base_path) do
    Enum.flat_map(nodes, fn %{document: doc, children: children} ->
      slug = doc.slug || "untitled"
      content = encode_frontmatter(doc.title, doc.position, doc.content || "")

      if children == [] do
        path = join_path(base_path, "#{slug}.md")
        [{~c"#{path}", content}]
      else
        path = join_path(base_path, "#{slug}/#{slug}.md")
        children_base = join_path(base_path, "#{slug}/children")
        [{~c"#{path}", content} | build_entries(children, children_base)]
      end
    end)
  end

  @doc """
  Encodes title, position, and content into markdown with frontmatter.
  """
  @spec encode_frontmatter(String.t(), integer(), String.t()) :: binary()
  def encode_frontmatter(title, position, content) do
    """
    ---
    title: #{yaml_escape(title)}
    position: #{position || 0}
    ---
    #{content}\
    """
  end

  defp join_path("", name), do: name
  defp join_path(base, name), do: "#{base}/#{name}"

  defp yaml_escape(value) when is_binary(value) do
    if String.contains?(value, [
         ":",
         "#",
         "'",
         "\"",
         "\n",
         "[",
         "]",
         "{",
         "}",
         ",",
         "&",
         "*",
         "?",
         "|",
         "-",
         "<",
         ">",
         "=",
         "!",
         "%",
         "@",
         "`"
       ]) or String.starts_with?(value, " ") or String.ends_with?(value, " ") do
      escaped = String.replace(value, "\"", "\\\"")
      "\"#{escaped}\""
    else
      value
    end
  end

  # coveralls-ignore-next-line
  defp yaml_escape(value), do: to_string(value)
end
