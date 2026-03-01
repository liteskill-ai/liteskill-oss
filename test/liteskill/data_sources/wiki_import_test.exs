defmodule Liteskill.DataSources.WikiImportTest do
  use Liteskill.DataCase, async: false
  use Oban.Testing, repo: Liteskill.Repo

  alias Liteskill.DataSources
  alias Liteskill.DataSources.WikiExport
  alias Liteskill.DataSources.WikiImport

  setup do
    {:ok, user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "import-test-#{System.unique_integer([:positive])}@example.com",
        name: "Import Tester",
        oidc_sub: "import-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{user: user}
  end

  describe "import_space/3 roundtrip" do
    test "imports an exported ZIP faithfully", %{user: user} do
      uniq = System.unique_integer([:positive])

      # Create a space with children
      {:ok, space} =
        DataSources.create_document(
          "builtin:wiki",
          %{title: "Roundtrip #{uniq}", content: "Root content"},
          user.id
        )

      {:ok, child} =
        DataSources.create_child_document(
          "builtin:wiki",
          space.id,
          %{title: "Child Page", content: "Child body"},
          user.id
        )

      {:ok, _grandchild} =
        DataSources.create_child_document(
          "builtin:wiki",
          child.id,
          %{title: "Grandchild", content: "Deep body"},
          user.id
        )

      # Export
      {:ok, {_filename, zip_binary}} = WikiExport.export_space(space.id, user.id)

      # Delete original to free the slug (simulates cross-instance export/import)
      {:ok, _} = DataSources.delete_document(space.id, user.id)

      # Import as new user
      {:ok, importer} =
        Liteskill.Accounts.find_or_create_from_oidc(%{
          email: "importer-#{System.unique_integer([:positive])}@example.com",
          name: "Importer",
          oidc_sub: "importer-#{System.unique_integer([:positive])}",
          oidc_issuer: "https://test.example.com"
        })

      {:ok, imported_space} = WikiImport.import_space(zip_binary, importer.id)

      assert imported_space.title == "Roundtrip #{uniq}"
      assert imported_space.content == "Root content"

      # Verify tree
      tree = DataSources.space_tree("builtin:wiki", imported_space.id, importer.id)
      assert length(tree) == 1
      child_node = hd(tree)
      assert child_node.document.title == "Child Page"
      assert child_node.document.content == "Child body"

      assert length(child_node.children) == 1
      grandchild_node = hd(child_node.children)
      assert grandchild_node.document.title == "Grandchild"
      assert grandchild_node.document.content == "Deep body"
    end
  end

  describe "import_space/3 with options" do
    test "uses space_title override", %{user: user} do
      zip_binary = build_test_zip("Original Name", "Some content", [])

      {:ok, space} = WikiImport.import_space(zip_binary, user.id, space_title: "Override Name")
      assert space.title == "Override Name"
    end

    test "falls back to manifest title when no override", %{user: user} do
      zip_binary = build_test_zip("Manifest Title", "", [])

      {:ok, space} = WikiImport.import_space(zip_binary, user.id)
      assert space.title == "Manifest Title"
    end
  end

  describe "import_space/3 with deeply nested pages" do
    test "imports 3 levels of nesting", %{user: user} do
      # Build a zip with: parent > child > grandchild
      entries = [
        {~c"manifest.json",
         Jason.encode!(%{
           version: 1,
           space_title: "Deep Space",
           space_content: "",
           exported_at: "2026-01-01T00:00:00Z"
         })},
        {~c"level1/level1.md", "---\ntitle: Level 1\nposition: 0\n---\nL1 content"},
        {~c"level1/children/level2/level2.md", "---\ntitle: Level 2\nposition: 0\n---\nL2 content"},
        {~c"level1/children/level2/children/level3.md", "---\ntitle: Level 3\nposition: 0\n---\nL3 content"}
      ]

      {:ok, {_, zip_binary}} = :zip.create(~c"test.zip", entries, [:memory])
      {:ok, space} = WikiImport.import_space(zip_binary, user.id)

      tree = DataSources.space_tree("builtin:wiki", space.id, user.id)
      assert length(tree) == 1

      l1 = hd(tree)
      assert l1.document.title == "Level 1"
      assert length(l1.children) == 1

      l2 = hd(l1.children)
      assert l2.document.title == "Level 2"
      assert length(l2.children) == 1

      l3 = hd(l2.children)
      assert l3.document.title == "Level 3"
      assert l3.document.content == "L3 content"
    end
  end

  describe "import_space/3 error cases" do
    test "returns error for missing manifest", %{user: user} do
      entries = [{~c"some-page.md", "---\ntitle: Page\nposition: 0\n---\nContent"}]
      {:ok, {_, zip_binary}} = :zip.create(~c"test.zip", entries, [:memory])

      assert {:error, :missing_manifest} = WikiImport.import_space(zip_binary, user.id)
    end

    test "returns error for malformed ZIP", %{user: user} do
      assert {:error, :invalid_zip} = WikiImport.import_space("not a zip file", user.id)
    end

    test "returns error for invalid manifest JSON", %{user: user} do
      entries = [{~c"manifest.json", "not json {{{"}]
      {:ok, {_, zip_binary}} = :zip.create(~c"test.zip", entries, [:memory])

      assert {:error, :invalid_manifest} = WikiImport.import_space(zip_binary, user.id)
    end
  end

  describe "parse_frontmatter/1" do
    test "parses standard frontmatter" do
      content = "---\ntitle: My Page\nposition: 3\n---\nBody text here"
      assert {"My Page", 3, "Body text here"} = WikiImport.parse_frontmatter(content)
    end

    test "defaults to Untitled and position 0 for missing frontmatter" do
      assert {"Untitled", 0, "Just plain text"} = WikiImport.parse_frontmatter("Just plain text")
    end

    test "handles empty content" do
      content = "---\ntitle: Empty\nposition: 0\n---\n"
      assert {"Empty", 0, ""} = WikiImport.parse_frontmatter(content)
    end

    test "handles non-binary input" do
      assert {"Untitled", 0, ""} = WikiImport.parse_frontmatter(nil)
    end

    test "handles missing position field" do
      content = "---\ntitle: No Position\n---\nBody"
      assert {"No Position", 0, "Body"} = WikiImport.parse_frontmatter(content)
    end

    test "handles missing title field" do
      content = "---\nposition: 5\n---\nBody"
      assert {"Untitled", 5, "Body"} = WikiImport.parse_frontmatter(content)
    end
  end

  describe "parse_entries/2" do
    test "parses leaf markdown files" do
      file_list = [
        {~c"manifest.json", "{}"},
        {~c"leaf-page.md", "---\ntitle: Leaf Page\nposition: 0\n---\nLeaf content"}
      ]

      entries = WikiImport.parse_entries(file_list, "")
      assert [%{title: "Leaf Page", content: "Leaf content", position: 0, children: []}] = entries
    end

    test "parses directory nodes with children" do
      file_list = [
        {~c"manifest.json", "{}"},
        {~c"parent/parent.md", "---\ntitle: Parent\nposition: 0\n---\nParent body"},
        {~c"parent/children/child.md", "---\ntitle: Child\nposition: 0\n---\nChild body"}
      ]

      entries = WikiImport.parse_entries(file_list, "")
      assert [%{title: "Parent", children: [%{title: "Child"}]}] = entries
    end

    test "handles directory without self-named .md file" do
      file_list = [
        {~c"manifest.json", "{}"},
        {~c"orphan-dir/children/child.md", "---\ntitle: Child\nposition: 0\n---\nChild body"}
      ]

      entries = WikiImport.parse_entries(file_list, "")
      assert [%{title: "Untitled", children: [%{title: "Child"}]}] = entries
    end

    test "sorts entries by position" do
      file_list = [
        {~c"manifest.json", "{}"},
        {~c"second.md", "---\ntitle: Second\nposition: 1\n---\n"},
        {~c"first.md", "---\ntitle: First\nposition: 0\n---\n"}
      ]

      entries = WikiImport.parse_entries(file_list, "")
      assert [%{title: "First", position: 0}, %{title: "Second", position: 1}] = entries
    end
  end

  # --- Helpers ---

  defp build_test_zip(space_title, space_content, page_entries) do
    manifest =
      Jason.encode!(%{
        version: 1,
        space_title: space_title,
        space_content: space_content,
        exported_at: "2026-01-01T00:00:00Z"
      })

    entries = [{~c"manifest.json", manifest} | page_entries]
    {:ok, {_, zip_binary}} = :zip.create(~c"test.zip", entries, [:memory])
    zip_binary
  end
end
