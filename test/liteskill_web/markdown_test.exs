defmodule LiteskillWeb.MarkdownTest do
  use ExUnit.Case, async: true

  alias LiteskillWeb.Markdown

  describe "render/1" do
    test "returns empty safe string for nil" do
      assert {:safe, ""} = Markdown.render(nil)
    end

    test "returns empty safe string for empty string" do
      assert {:safe, ""} = Markdown.render("")
    end

    test "renders basic markdown" do
      {:safe, html} = Markdown.render("**bold** text")
      assert html =~ "<strong>bold</strong>"
      assert html =~ "text"
    end

    test "renders regular code blocks unmodified" do
      {:safe, html} = Markdown.render("```elixir\nIO.puts(\"hi\")\n```")
      assert html =~ "IO"
      refute html =~ "phx-hook"
    end
  end

  # -- ```spec blocks (JSONL patches — the library's native format) ----------

  describe "spec block detection (JSONL patches)" do
    test "replaces spec fenced block with hook div" do
      jsonl = """
      {"op":"add","path":"/root","value":"main"}
      {"op":"add","path":"/elements/main","value":{"type":"Card","props":{"title":"Hello"},"children":[]}}
      """

      md = "Here is a visual:\n\n```spec\n#{String.trim(jsonl)}\n```\n\nSome text after."
      {:safe, html} = Markdown.render(md)

      assert html =~ ~s(phx-hook="JsonRender")
      assert html =~ ~s(phx-update="ignore")
      assert html =~ ~s(data-format="jsonl")
      assert html =~ "data-spec="
      assert html =~ "Some text after"
    end

    test "preserves JSONL content in data-spec" do
      jsonl =
        ~S|{"op":"add","path":"/root","value":"main"}| <>
          "\n" <>
          ~S|{"op":"add","path":"/elements/main","value":{"type":"Metric","props":{"label":"Revenue","value":"$1M"},"children":[]}}|

      md = "```spec\n#{jsonl}\n```"
      {:safe, html} = Markdown.render(md)

      assert html =~ ~s(phx-hook="JsonRender")
      assert html =~ "Revenue"
      assert html =~ "Metric"
    end

    test "leaves invalid JSONL as a regular code block" do
      md = "```spec\nthis is not jsonl at all\n```"
      {:safe, html} = Markdown.render(md)

      refute html =~ ~s(phx-hook="JsonRender")
      assert html =~ "language-spec"
      assert html =~ "this is not jsonl"
    end

    test "handles multiple spec blocks" do
      md = """
      ```spec
      {"op":"add","path":"/root","value":"a"}
      ```

      ```spec
      {"op":"add","path":"/root","value":"b"}
      ```
      """

      {:safe, html} = Markdown.render(md)
      hook_count = length(Regex.scan(~r/phx-hook="JsonRender"/, html))
      assert hook_count == 2
    end

    test "spec blocks get unique ids" do
      md = """
      ```spec
      {"op":"add","path":"/root","value":"a"}
      ```

      ```spec
      {"op":"add","path":"/root","value":"b"}
      ```
      """

      {:safe, html} = Markdown.render(md)
      ids = Regex.scan(~r/id="(jr-\d+)"/, html) |> Enum.map(&List.last/1)
      assert length(ids) == 2
      assert Enum.uniq(ids) == ids
    end

    test "handles streaming mode with complete spec block" do
      jsonl = ~S|{"op":"add","path":"/root","value":"main"}|
      md = "```spec\n#{jsonl}\n```"
      {:safe, html} = Markdown.render_streaming(md)
      assert html =~ ~s(phx-hook="JsonRender")
      assert html =~ ~s(data-format="jsonl")
    end
  end

  # -- ```json-render blocks (legacy nested JSON format) ---------------------

  describe "json-render block detection (legacy)" do
    test "replaces json-render fenced block with hook div" do
      md = """
      Here is a visual:

      ```json-render
      {"root":{"type":"Card","props":{"title":"Test"},"children":[]}}
      ```

      Some text after.
      """

      {:safe, html} = Markdown.render(md)

      assert html =~ ~s(phx-hook="JsonRender")
      assert html =~ ~s(phx-update="ignore")
      assert html =~ "data-spec="
      # Legacy format should NOT have data-format="jsonl"
      refute html =~ ~s(data-format="jsonl")
      assert html =~ "Some text after"
    end

    test "preserves valid JSON in data-spec attribute" do
      json =
        ~S|{"root":{"type":"Metric","props":{"label":"Revenue","value":"$1M"},"children":[]}}|

      md = "```json-render\n#{json}\n```"
      {:safe, html} = Markdown.render(md)

      assert html =~ ~s(phx-hook="JsonRender")
      assert html =~ "Revenue"
      assert html =~ "Metric"
    end

    test "leaves invalid JSON as a regular code block" do
      md = "```json-render\nthis is not json {{\n```"

      {:safe, html} = Markdown.render(md)

      refute html =~ ~s(phx-hook="JsonRender")
      assert html =~ "language-json-render"
      assert html =~ "this is not json"
    end

    test "handles multiple json-render blocks in one message" do
      md = """
      ```json-render
      {"root":{"type":"Card","props":{"title":"One"},"children":[]}}
      ```

      ```json-render
      {"root":{"type":"Card","props":{"title":"Two"},"children":[]}}
      ```
      """

      {:safe, html} = Markdown.render(md)
      hook_count = length(Regex.scan(~r/phx-hook="JsonRender"/, html))
      assert hook_count == 2
    end

    test "each json-render block gets a unique id" do
      md = """
      ```json-render
      {"root":{"type":"Card","props":{"title":"A"},"children":[]}}
      ```

      ```json-render
      {"root":{"type":"Card","props":{"title":"B"},"children":[]}}
      ```
      """

      {:safe, html} = Markdown.render(md)
      ids = Regex.scan(~r/id="(jr-\d+)"/, html) |> Enum.map(&List.last/1)
      assert length(ids) == 2
      assert Enum.uniq(ids) == ids
    end

    test "handles complete json-render blocks in streaming mode" do
      md =
        ~s|```json-render\n{"root":{"type":"Card","props":{"title":"Test"},"children":[]}}\n```|

      {:safe, html} = Markdown.render_streaming(md)
      assert html =~ ~s(phx-hook="JsonRender")
    end
  end

  # -- ```json fallback detection --------------------------------------------

  describe "json fallback detection" do
    test "does not interfere with regular json code blocks" do
      md = """
      ```json
      {"key": "value"}
      ```
      """

      {:safe, html} = Markdown.render(md)
      refute html =~ ~s(phx-hook="JsonRender")
    end

    test "detects nested json-render spec inside a json block" do
      json = ~S|{"root":{"type":"Card","props":{"title":"Test"},"children":[]}}|
      md = "```json\n#{json}\n```"
      {:safe, html} = Markdown.render(md)

      assert html =~ ~s(phx-hook="JsonRender")
      assert html =~ "data-spec="
    end

    test "detects flat json-render spec inside a json block" do
      json =
        ~S|{"root":"main","elements":{"main":{"type":"Card","props":{"title":"X"},"children":[]}}}|

      md = "```json\n#{json}\n```"
      {:safe, html} = Markdown.render(md)

      assert html =~ ~s(phx-hook="JsonRender")
    end

    test "does not treat non-spec json blocks as json-render" do
      md = """
      ```json
      {"users": [{"name": "Alice"}, {"name": "Bob"}]}
      ```
      """

      {:safe, html} = Markdown.render(md)
      refute html =~ ~s(phx-hook="JsonRender")
    end

    test "properly escapes special characters in data-spec" do
      json =
        ~S|{"root":{"type":"Alert","props":{"message":"A & B","severity":"info"},"children":[]}}|

      md = "```json-render\n#{json}\n```"
      {:safe, html} = Markdown.render(md)

      assert html =~ ~s(phx-hook="JsonRender")
      assert html =~ "data-spec="
    end
  end

  # -- bare JSONL heuristic detection -----------------------------------------

  describe "bare JSONL heuristic detection" do
    test "detects bare JSONL patch lines not in any code fence" do
      md = """
      Here's a dashboard!

      {"op":"add","path":"/root","value":"main"}
      {"op":"add","path":"/elements/main","value":{"type":"Card","props":{"title":"Hello"},"children":[]}}

      Some text after.
      """

      {:safe, html} = Markdown.render(md)

      assert html =~ ~s(phx-hook="JsonRender")
      assert html =~ ~s(data-format="jsonl")
      assert html =~ "Some text after"
      assert html =~ "dashboard"
    end

    test "detects many consecutive bare patch lines" do
      patches =
        Enum.join(
          [
            ~S|{"op":"add","path":"/root","value":"dash"}|,
            ~S|{"op":"add","path":"/elements/dash","value":{"type":"Grid","props":{"columns":2},"children":["a","b"]}}|,
            ~S|{"op":"add","path":"/elements/a","value":{"type":"Metric","props":{"label":"X","value":"1"},"children":[]}}|,
            ~S|{"op":"add","path":"/elements/b","value":{"type":"Metric","props":{"label":"Y","value":"2"},"children":[]}}|
          ],
          "\n"
        )

      md = "Visual:\n\n#{patches}\n\nDone."
      {:safe, html} = Markdown.render(md)

      assert html =~ ~s(phx-hook="JsonRender")
      assert html =~ "Done"
    end

    test "groups patch lines separated by blank lines into one block" do
      # LLMs often emit patches with blank lines between them
      md =
        Enum.join(
          [
            "Here's a dashboard!\n",
            ~S|{"op":"add","path":"/root","value":"main"}|,
            ~S|{"op":"add","path":"/elements/main","value":{"type":"Card","props":{"title":"A"},"children":["m1"]}}|,
            "",
            ~S|{"op":"add","path":"/elements/m1","value":{"type":"Metric","props":{"label":"X","value":"1"},"children":[]}}|,
            "",
            ~S|{"op":"add","path":"/state/count","value":42}|,
            "",
            "Some text after."
          ],
          "\n"
        )

      {:safe, html} = Markdown.render(md)

      # Should produce exactly ONE hook div (all patches grouped together)
      hook_count = length(Regex.scan(~r/phx-hook="JsonRender"/, html))
      assert hook_count == 1

      assert html =~ "dashboard"
      assert html =~ "Some text after"
    end

    test "does not treat a single JSON line as a spec block" do
      # One line is not enough — could be a coincidence
      md = ~S|Some text {"op":"add","path":"/foo","value":"bar"} more text|
      {:safe, html} = Markdown.render(md)

      refute html =~ ~s(phx-hook="JsonRender")
    end

    test "does not interfere with regular JSON objects" do
      md = """
      {"name": "Alice"}
      {"name": "Bob"}
      """

      {:safe, html} = Markdown.render(md)
      refute html =~ ~s(phx-hook="JsonRender")
    end

    test "handles bare JSONL in streaming mode" do
      patches =
        ~S|{"op":"add","path":"/root","value":"main"}| <>
          "\n" <>
          ~S|{"op":"add","path":"/elements/main","value":{"type":"Card","props":{"title":"Hi"},"children":[]}}|

      md = "Result:\n\n#{patches}"
      {:safe, html} = Markdown.render_streaming(md)

      assert html =~ ~s(phx-hook="JsonRender")
      assert html =~ ~s(data-format="jsonl")
    end
  end

  # -- render_streaming/1 basics ---------------------------------------------

  describe "render_streaming/1" do
    test "returns empty safe string for nil" do
      assert {:safe, ""} = Markdown.render_streaming(nil)
    end

    test "returns empty safe string for empty string" do
      assert {:safe, ""} = Markdown.render_streaming("")
    end

    test "renders streaming markdown" do
      {:safe, html} = Markdown.render_streaming("**bold**")
      assert html =~ "<strong>bold</strong>"
    end
  end

  # -- extract_visual_blocks/1 -----------------------------------------------

  describe "extract_visual_blocks/1" do
    test "extracts json-render fenced blocks and replaces with placeholders" do
      md = """
      Hello

      ```json-render
      {"type": "Card"}
      ```

      World
      """

      {cleaned, placeholders} = Markdown.extract_visual_blocks(md)

      assert map_size(placeholders) == 1
      refute cleaned =~ "json-render"
      assert cleaned =~ "Hello"
      assert cleaned =~ "World"
      assert cleaned =~ "JRBLOCK"

      [{_id, {:json, content}}] = Map.to_list(placeholders)
      assert content =~ "Card"
    end

    test "extracts spec fenced blocks with jsonl format tag" do
      md = """
      ```spec
      {"op":"add","path":"/root","value":"main"}
      ```
      """

      {cleaned, placeholders} = Markdown.extract_visual_blocks(md)

      assert map_size(placeholders) == 1
      [{_id, {format, _content}}] = Map.to_list(placeholders)
      assert format == :jsonl
      assert cleaned =~ "JRBLOCK"
    end

    test "returns unmodified markdown when no visual blocks exist" do
      md = "Just plain text"
      {cleaned, placeholders} = Markdown.extract_visual_blocks(md)
      assert cleaned == md
      assert placeholders == %{}
    end

    test "handles multiple blocks of different types" do
      md = """
      ```spec
      {"op":"add","path":"/root","value":"a"}
      ```

      ```json-render
      {"root":{"type":"Card","props":{"title":"B"},"children":[]}}
      ```
      """

      {_cleaned, placeholders} = Markdown.extract_visual_blocks(md)
      assert map_size(placeholders) == 2

      formats = placeholders |> Map.values() |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      assert formats == [:json, :jsonl]
    end
  end

  # -- restore_visual_blocks/2 -----------------------------------------------

  describe "restore_visual_blocks/2" do
    test "is a no-op when no placeholders" do
      html = "<p>Hello</p>"
      assert Markdown.restore_visual_blocks(html, %{}) == html
    end

    test "replaces placeholder with hook div for valid JSON" do
      id = :erlang.unique_integer([:positive])
      json = ~S|{"root":{"type":"Card","props":{"title":"X"},"children":[]}}|

      html = "<p>Before</p><p>JRBLOCK#{id}JREND</p><p>After</p>"
      result = Markdown.restore_visual_blocks(html, %{id => {:json, json}})

      assert result =~ ~s(phx-hook="JsonRender")
      assert result =~ ~s(phx-update="ignore")
      assert result =~ "Before"
      assert result =~ "After"
    end

    test "replaces placeholder with code block for invalid JSON" do
      id = :erlang.unique_integer([:positive])

      html = "<p>JRBLOCK#{id}JREND</p>"
      result = Markdown.restore_visual_blocks(html, %{id => {:json, "not valid json {{"}})

      refute result =~ ~s(phx-hook="JsonRender")
      assert result =~ "language-json-render"
      assert result =~ "not valid json"
    end

    test "replaces placeholder with hook div for valid JSONL" do
      id = :erlang.unique_integer([:positive])
      jsonl = ~S|{"op":"add","path":"/root","value":"main"}|

      html = "<p>JRBLOCK#{id}JREND</p>"
      result = Markdown.restore_visual_blocks(html, %{id => {:jsonl, jsonl}})

      assert result =~ ~s(phx-hook="JsonRender")
      assert result =~ ~s(data-format="jsonl")
    end

    test "replaces placeholder with code block for invalid JSONL" do
      id = :erlang.unique_integer([:positive])

      html = "<p>JRBLOCK#{id}JREND</p>"
      result = Markdown.restore_visual_blocks(html, %{id => {:jsonl, "garbage data"}})

      refute result =~ ~s(phx-hook="JsonRender")
      assert result =~ "language-spec"
    end
  end
end
