defmodule Liteskill.DataSources.WikiImport do
  @moduledoc """
  Imports a wiki space from a ZIP file produced by `WikiExport`.

  Parses the manifest and markdown files with frontmatter,
  then creates the space and child documents in the correct hierarchy.
  """

  alias Liteskill.DataSources

  @doc """
  Imports a wiki space from a ZIP binary.

  ## Options
    * `:space_title` - override the space title from the manifest

  Returns `{:ok, space_doc}` or `{:error, reason}`.
  """
  @spec import_space(binary(), Ecto.UUID.t(), keyword()) ::
          {:ok, Ecto.Schema.t()} | {:error, term()}
  def import_space(zip_binary, user_id, opts \\ []) do
    with {:ok, file_list} <- extract_zip(zip_binary),
         {:ok, manifest} <- read_manifest(file_list),
         {:ok, space_doc} <- create_space(manifest, user_id, opts),
         :ok <- create_children(file_list, space_doc.id, user_id) do
      {:ok, space_doc}
    end
  end

  defp extract_zip(zip_binary) do
    case :zip.unzip(zip_binary, [:memory]) do
      {:ok, file_list} -> {:ok, file_list}
      {:error, _reason} -> {:error, :invalid_zip}
    end
  end

  defp read_manifest(file_list) do
    case List.keyfind(file_list, ~c"manifest.json", 0) do
      {_, manifest_bin} ->
        case Jason.decode(manifest_bin) do
          {:ok, manifest} -> {:ok, manifest}
          {:error, _} -> {:error, :invalid_manifest}
        end

      nil ->
        {:error, :missing_manifest}
    end
  end

  defp create_space(manifest, user_id, opts) do
    title = Keyword.get(opts, :space_title) || manifest["space_title"] || "Imported Space"
    content = manifest["space_content"]

    attrs = %{title: title, content_type: "markdown"}
    attrs = if content && content != "", do: Map.put(attrs, :content, content), else: attrs

    DataSources.create_document("builtin:wiki", attrs, user_id)
  end

  defp create_children(file_list, space_id, user_id) do
    entries = parse_entries(file_list, "")
    create_nodes(entries, space_id, user_id)
  end

  @doc """
  Parses ZIP file entries into a hierarchical tree structure.

  Returns a sorted list of `%{title, content, position, children}` maps.
  """
  @spec parse_entries([{charlist(), binary()}], String.t()) :: [map()]
  def parse_entries(file_list, base_path) do
    # Filter to files under base_path, stripping manifest
    prefix = if base_path == "", do: "", else: "#{base_path}/"

    relevant =
      file_list
      |> Enum.map(fn {path_charlist, content} -> {to_string(path_charlist), content} end)
      |> Enum.filter(fn {path, _} ->
        path != "manifest.json" and String.starts_with?(path, prefix)
      end)
      |> Enum.map(fn {path, content} ->
        relative = String.replace_prefix(path, prefix, "")
        {relative, content}
      end)

    # Group by top-level entry
    groups =
      Enum.group_by(relevant, fn {relative, _} ->
        relative |> String.split("/", parts: 2) |> hd()
      end)

    groups
    |> Enum.map(fn {top_entry, files} ->
      if String.ends_with?(top_entry, ".md") do
        # Leaf node: single .md file
        {_, content_bin} = List.keyfind(files, top_entry, 0, {top_entry, ""})
        {title, position, content} = parse_frontmatter(content_bin)
        %{title: title, content: content, position: position, children: []}
      else
        # Directory node: has slug/slug.md + optional slug/children/
        slug = top_entry
        self_path = "#{slug}/#{slug}.md"

        self_content =
          case List.keyfind(files, self_path, 0) do
            {_, bin} -> bin
            nil -> ""
          end

        {title, position, content} = parse_frontmatter(self_content)
        children_prefix = "#{slug}/children"

        children_files =
          file_list
          |> Enum.map(fn {p, c} -> {to_string(p), c} end)
          |> Enum.filter(fn {path, _} ->
            full_prefix =
              if prefix == "", do: children_prefix, else: "#{prefix}#{children_prefix}"

            String.starts_with?(path, "#{full_prefix}/")
          end)
          |> Enum.map(fn {path, c} -> {String.to_charlist(path), c} end)

        child_base =
          if prefix == "", do: children_prefix, else: "#{prefix}#{children_prefix}"

        children = parse_entries(children_files, child_base)

        %{title: title, content: content, position: position, children: children}
      end
    end)
    |> Enum.sort_by(& &1.position)
  end

  @doc """
  Parses YAML-style frontmatter from markdown content.

  Returns `{title, position, body}`.
  """
  @spec parse_frontmatter(binary()) :: {String.t(), integer(), String.t()}
  def parse_frontmatter(content) when is_binary(content) do
    case String.split(content, "---", parts: 3) do
      ["", frontmatter, body] ->
        title = extract_field(frontmatter, "title") || "Untitled"
        position = extract_position(frontmatter)
        {title, position, String.trim_leading(body, "\n")}

      _ ->
        {"Untitled", 0, content}
    end
  end

  def parse_frontmatter(_), do: {"Untitled", 0, ""}

  defp extract_field(text, field) do
    case Regex.run(~r/^#{field}:\s*(.+)$/m, text) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end

  defp extract_position(text) do
    case extract_field(text, "position") do
      nil -> 0
      val -> String.to_integer(val)
    end
  rescue
    # coveralls-ignore-next-line
    _e in [ArgumentError] -> 0
  end

  defp create_nodes(entries, parent_id, user_id) do
    Enum.reduce_while(entries, :ok, fn node, :ok ->
      attrs = %{
        content_type: "markdown",
        title: node.title,
        content: node.content,
        position: node.position
      }

      case DataSources.create_child_document("builtin:wiki", parent_id, attrs, user_id) do
        {:ok, doc} ->
          case create_nodes(node.children, doc.id, user_id) do
            :ok -> {:cont, :ok}
            # coveralls-ignore-next-line
            error -> {:halt, error}
          end

        # coveralls-ignore-start
        {:error, reason} ->
          {:halt, {:error, reason}}
          # coveralls-ignore-stop
      end
    end)
  end
end
