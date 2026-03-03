defmodule Liteskill.DataSources.ContentExtractorTest do
  use ExUnit.Case, async: true

  alias Liteskill.DataSources.ContentExtractor

  describe "extract/2" do
    test "passes through text/plain" do
      assert {:ok, "Hello world"} = ContentExtractor.extract("Hello world", "text/plain")
    end

    test "passes through text/markdown" do
      assert {:ok, "# Title"} = ContentExtractor.extract("# Title", "text/markdown")
    end

    test "passes through markdown shorthand" do
      assert {:ok, "# Title"} = ContentExtractor.extract("# Title", "markdown")
    end

    test "passes through application/json" do
      json = ~s({"key": "value"})
      assert {:ok, ^json} = ContentExtractor.extract(json, "application/json")
    end

    test "passes through generic text types" do
      assert {:ok, "data"} = ContentExtractor.extract("data", "text/csv")
    end

    test "strips HTML tags from text/html" do
      html = "<html><body><h1>Title</h1><p>Hello</p></body></html>"
      {:ok, text} = ContentExtractor.extract(html, "text/html")
      assert text =~ "Title"
      assert text =~ "Hello"
      refute text =~ "<"
    end

    test "strips script and style tags from HTML" do
      html = """
      <html>
      <head><style>body { color: red; }</style></head>
      <body>
      <script>alert('xss')</script>
      <p>Content</p>
      </body>
      </html>
      """

      {:ok, text} = ContentExtractor.extract(html, "text/html")
      assert text =~ "Content"
      refute text =~ "alert"
      refute text =~ "color: red"
    end

    test "returns error for unsupported content types" do
      assert {:error, :unsupported_content_type} =
               ContentExtractor.extract("binary", "application/pdf")

      assert {:error, :unsupported_content_type} =
               ContentExtractor.extract("binary", "image/png")
    end
  end
end
