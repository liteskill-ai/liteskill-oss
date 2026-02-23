defmodule LiteskillWeb.Markdown do
  @moduledoc """
  Converts Markdown content to safe HTML for rendering in the chat UI.
  """

  @mdex_opts [
    extension: [
      table: true,
      strikethrough: true,
      autolink: true,
      tasklist: true,
      footnotes: true
    ],
    render: [
      github_pre_lang: true
    ],
    syntax_highlight: [
      formatter: {:html_inline, theme: "onedark"}
    ]
  ]

  @uuid_re ~r/\[uuid:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\]/

  # Matches ```spec ... ``` fenced code blocks — the json-render library's
  # native format containing JSONL patches (one RFC 6902 op per line).
  @spec_fence_re ~r/```spec\s*\n([\s\S]*?)```/

  # Legacy: matches ```json-render ... ``` fenced code blocks containing a
  # single nested JSON spec tree.
  @json_render_fence_re ~r/```json-render\s*\n([\s\S]*?)```/

  # Fallback: matches ```json blocks that contain a json-render spec
  # structure. LLMs sometimes use ```json instead of ```json-render despite
  # explicit instructions. We detect these by checking if the JSON content
  # has the {"root": {"type": ...}} structure (nested) or flat spec keys.
  @json_spec_fence_re ~r/```json\s*\n([\s\S]*?)```/

  @doc """
  Renders a complete markdown string to an HTML-safe Phoenix.HTML struct.
  """
  def render(nil), do: {:safe, ""}
  def render(""), do: {:safe, ""}

  def render(markdown) when is_binary(markdown) do
    {cleaned, placeholders} = extract_visual_blocks(markdown)

    {:safe,
     cleaned
     |> MDEx.to_html!(@mdex_opts)
     |> replace_citations()
     |> restore_visual_blocks(placeholders)}
  end

  @doc """
  Renders a streaming (potentially incomplete) markdown fragment.
  Uses mdex's streaming mode which auto-closes unclosed nodes.
  """
  def render_streaming(nil), do: {:safe, ""}
  def render_streaming(""), do: {:safe, ""}

  def render_streaming(markdown) when is_binary(markdown) do
    {cleaned, placeholders} = extract_visual_blocks(markdown)

    html =
      MDEx.new(Keyword.merge(@mdex_opts, streaming: true, markdown: cleaned))
      |> MDEx.to_html!()

    {:safe, html |> replace_citations() |> restore_visual_blocks(placeholders)}
  end

  defp replace_citations(html) do
    {result, _n} =
      Regex.scan(@uuid_re, html)
      |> Enum.reduce({html, 1}, fn [full_match, uuid], {acc, n} ->
        replacement =
          ~s(<button class="rag-cite" phx-click="show_source" phx-value-doc-id="#{uuid}">#{n}</button>)

        {String.replace(acc, full_match, replacement, global: false), n + 1}
      end)

    result
  end

  # -- visual block extraction ------------------------------------------------

  @doc false
  def extract_visual_blocks(markdown) do
    # Pass 1: ```spec blocks (JSONL patches — the library's native format)
    {md1, ph1} = extract_by_regex(markdown, @spec_fence_re, format: :jsonl)

    # Pass 2: ```json-render blocks (legacy nested JSON spec)
    {md2, ph2} = extract_by_regex(md1, @json_render_fence_re, format: :json)

    # Pass 3: ```json blocks that look like json-render specs (fallback)
    {md3, ph3} = extract_by_regex(md2, @json_spec_fence_re, format: :json, validate: true)

    # Pass 4: Heuristic — detect bare JSONL patch lines not inside any fence.
    # LLMs sometimes emit raw JSONL without wrapping in ```spec.  The
    # json-render library handles this with its own "heuristic mode".
    {md4, ph4} = extract_bare_jsonl_blocks(md3)

    {md4, ph1 |> Map.merge(ph2) |> Map.merge(ph3) |> Map.merge(ph4)}
  end

  defp extract_by_regex(markdown, regex, opts) do
    validate? = Keyword.get(opts, :validate, false)
    format = Keyword.fetch!(opts, :format)

    Regex.scan(regex, markdown, return: :index)
    |> Enum.reverse()
    |> Enum.reduce({markdown, %{}}, fn [{start, len}, {content_start, content_len}], {md, acc} ->
      content = String.slice(markdown, content_start, content_len) |> String.trim()

      if validate? and not json_render_spec?(content) do
        # Not a json-render spec — leave it as a regular code block
        {md, acc}
      else
        id = :erlang.unique_integer([:positive])
        # Use a text placeholder that MDEx will pass through as a paragraph.
        placeholder = "JRBLOCK#{id}JREND"

        new_md =
          String.slice(md, 0, start) <>
            placeholder <>
            String.slice(md, (start + len)..-1//1)

        {new_md, Map.put(acc, id, {format, content})}
      end
    end)
  end

  # Heuristic mode: scan for bare JSONL patch lines not inside any code fence.
  # LLMs often emit patches interspersed with blank lines, so we allow
  # blank-line gaps within a single block — only non-blank, non-patch text
  # terminates the current block.  Requires 2+ patch lines to trigger.
  defp extract_bare_jsonl_blocks(markdown) do
    lines = String.split(markdown, "\n")

    # State: {result_lines, patch_lines, blank_buffer, placeholders}
    #   patch_lines — accumulated JSONL patch lines (reversed)
    #   blank_buffer — blank lines seen since last patch (reversed);
    #                  absorbed if another patch follows, restored if text follows
    {result_lines, patch_lines, blank_buffer, placeholders} =
      Enum.reduce(lines, {[], [], [], %{}}, fn line, {result, patches, blanks, ph} ->
        trimmed = String.trim(line)

        cond do
          jsonl_patch_line?(line) ->
            # Patch line — absorb any buffered blanks and continue the block
            {result, [line | patches], [], ph}

          patches != [] and trimmed == "" ->
            # Blank line while we have accumulated patches — buffer it
            {result, patches, [line | blanks], ph}

          true ->
            # Non-patch, non-blank line → flush any accumulated patches
            {result, ph} = flush_jsonl_block(result, patches, ph)
            # Restore buffered blanks as regular text, then this line
            result = [line | Enum.reverse(blanks) ++ result]
            {result, [], [], ph}
        end
      end)

    # Flush any trailing patches
    {result_lines, placeholders} =
      flush_jsonl_block(result_lines, patch_lines, placeholders)

    # Restore any trailing blanks
    result_lines = Enum.reverse(blank_buffer) ++ result_lines

    cleaned = result_lines |> Enum.reverse() |> Enum.join("\n")
    {cleaned, placeholders}
  end

  # Flush accumulated JSONL patch lines into a placeholder.
  # Requires at least 2 patch lines to avoid false positives.
  defp flush_jsonl_block(result_lines, [], placeholders), do: {result_lines, placeholders}

  defp flush_jsonl_block(result_lines, [single], placeholders) do
    # Single line — not confident enough; leave as-is
    {[single | result_lines], placeholders}
  end

  defp flush_jsonl_block(result_lines, patches, placeholders) when length(patches) >= 2 do
    content = patches |> Enum.reverse() |> Enum.join("\n") |> String.trim()
    id = :erlang.unique_integer([:positive])
    placeholder = "JRBLOCK#{id}JREND"
    {[placeholder | result_lines], Map.put(placeholders, id, {:jsonl, content})}
  end

  # Quick check: does this line look like a JSONL spec patch?
  # Uses string prefix matching for speed, avoids JSON parsing every line.
  defp jsonl_patch_line?(line) do
    trimmed = String.trim(line)
    String.starts_with?(trimmed, "{\"op\":") and String.contains?(trimmed, "\"path\":")
  end

  # Check if a JSON string looks like a json-render spec.
  # Nested format: {"root": {"type": ..., "props": ...}}
  # Flat format: {"root": "key", "elements": {...}}
  defp json_render_spec?(json) do
    case Jason.decode(json) do
      {:ok, %{"root" => %{"type" => _, "props" => _}}} -> true
      {:ok, %{"root" => _, "elements" => _}} -> true
      _ -> false
    end
  end

  @doc false
  def restore_visual_blocks(html, placeholders) when map_size(placeholders) == 0, do: html

  def restore_visual_blocks(html, placeholders) do
    Enum.reduce(placeholders, html, fn {id, {format, content}}, acc ->
      replacement = build_hook_div(id, format, content)
      placeholder_text = "JRBLOCK#{id}JREND"

      # MDEx wraps the placeholder in a <p> tag — replace both forms
      acc
      |> String.replace("<p>#{placeholder_text}</p>", replacement)
      |> String.replace(placeholder_text, replacement)
    end)
  end

  # Build the <div> with phx-hook for the JsonRender LiveView hook.
  # For JSONL (```spec), content is multi-line JSONL patches — validate at
  # least one line is parseable JSON.
  # For JSON (```json-render / ```json), content is a single JSON object.
  defp build_hook_div(id, :jsonl, content) do
    has_valid_line =
      content
      |> String.split("\n", trim: true)
      |> Enum.any?(fn line ->
        case Jason.decode(String.trim(line)) do
          {:ok, _} -> true
          _ -> false
        end
      end)

    if has_valid_line do
      dom_id = "jr-#{id}"
      escaped = content |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()

      ~s(<div id="#{dom_id}" phx-hook="JsonRender" phx-update="ignore" data-format="jsonl" data-spec="#{escaped}"></div>)
    else
      escaped = content |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
      ~s(<pre><code class="language-spec">#{escaped}</code></pre>)
    end
  end

  defp build_hook_div(id, :json, content) do
    case Jason.decode(content) do
      {:ok, _} ->
        dom_id = "jr-#{id}"
        escaped = content |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()

        ~s(<div id="#{dom_id}" phx-hook="JsonRender" phx-update="ignore" data-spec="#{escaped}"></div>)

      {:error, _} ->
        escaped = content |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
        ~s(<pre><code class="language-json-render">#{escaped}</code></pre>)
    end
  end
end
