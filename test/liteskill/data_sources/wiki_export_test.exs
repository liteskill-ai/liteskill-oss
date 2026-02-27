defmodule Liteskill.DataSources.WikiExportTest do
  use Liteskill.DataCase, async: false
  use Oban.Testing, repo: Liteskill.Repo

  alias Liteskill.DataSources
  alias Liteskill.DataSources.WikiExport

  setup do
    {:ok, user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "export-test-#{System.unique_integer([:positive])}@example.com",
        name: "Export Tester",
        oidc_sub: "export-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{user: user}
  end

  describe "export_space/2" do
    test "exports a space with nested children (3 levels deep)", %{user: user} do
      {:ok, space} =
        DataSources.create_document(
          "builtin:wiki",
          %{title: "Test Space", content: "Root content"},
          user.id
        )

      {:ok, child1} =
        DataSources.create_child_document(
          "builtin:wiki",
          space.id,
          %{title: "Child One", content: "Child 1 body"},
          user.id
        )

      {:ok, _child2} =
        DataSources.create_child_document(
          "builtin:wiki",
          space.id,
          %{title: "Child Two", content: "Child 2 body"},
          user.id
        )

      {:ok, _grandchild} =
        DataSources.create_child_document(
          "builtin:wiki",
          child1.id,
          %{title: "Grandchild", content: "Deep content"},
          user.id
        )

      assert {:ok, {filename, zip_binary}} = WikiExport.export_space(space.id, user.id)
      assert filename == "#{space.slug}.zip"
      assert is_binary(zip_binary)
      assert byte_size(zip_binary) > 0

      # Verify ZIP contents
      {:ok, file_list} = :zip.unzip(zip_binary, [:memory])
      paths = Enum.map(file_list, fn {path, _} -> to_string(path) end) |> Enum.sort()

      assert "manifest.json" in paths
      assert "child-one/child-one.md" in paths
      assert "child-two.md" in paths
      assert "child-one/children/grandchild.md" in paths

      # Verify manifest
      {_, manifest_bin} = List.keyfind(file_list, ~c"manifest.json", 0)
      manifest = Jason.decode!(manifest_bin)
      assert manifest["version"] == 1
      assert manifest["space_title"] == "Test Space"
      assert manifest["space_content"] == "Root content"
      assert manifest["exported_at"]
    end

    test "exports an empty space (no children)", %{user: user} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "Empty Space"}, user.id)

      assert {:ok, {filename, zip_binary}} = WikiExport.export_space(space.id, user.id)
      assert filename == "#{space.slug}.zip"

      {:ok, file_list} = :zip.unzip(zip_binary, [:memory])
      paths = Enum.map(file_list, fn {path, _} -> to_string(path) end)

      # Should only have manifest
      assert paths == ["manifest.json"]
    end

    test "exports space with content on root", %{user: user} do
      {:ok, space} =
        DataSources.create_document(
          "builtin:wiki",
          %{title: "Content Space", content: "# Hello\n\nThis is root."},
          user.id
        )

      assert {:ok, {_filename, zip_binary}} = WikiExport.export_space(space.id, user.id)

      {:ok, file_list} = :zip.unzip(zip_binary, [:memory])
      {_, manifest_bin} = List.keyfind(file_list, ~c"manifest.json", 0)
      manifest = Jason.decode!(manifest_bin)
      assert manifest["space_content"] == "# Hello\n\nThis is root."
    end

    test "returns error for nonexistent space", %{user: user} do
      assert {:error, :not_found} = WikiExport.export_space(Ecto.UUID.generate(), user.id)
    end

    test "returns error for space not accessible by user" do
      {:ok, owner} =
        Liteskill.Accounts.find_or_create_from_oidc(%{
          email: "owner-#{System.unique_integer([:positive])}@example.com",
          name: "Owner",
          oidc_sub: "owner-#{System.unique_integer([:positive])}",
          oidc_issuer: "https://test.example.com"
        })

      {:ok, other} =
        Liteskill.Accounts.find_or_create_from_oidc(%{
          email: "other-#{System.unique_integer([:positive])}@example.com",
          name: "Other",
          oidc_sub: "other-#{System.unique_integer([:positive])}",
          oidc_issuer: "https://test.example.com"
        })

      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "Private Space"}, owner.id)

      assert {:error, :not_found} = WikiExport.export_space(space.id, other.id)
    end
  end

  describe "encode_frontmatter/3" do
    test "encodes title, position, and content" do
      result = WikiExport.encode_frontmatter("My Page", 2, "Some content here")
      assert result =~ "---\n"
      assert result =~ "title: My Page"
      assert result =~ "position: 2"
      assert result =~ "Some content here"
    end

    test "handles nil position" do
      result = WikiExport.encode_frontmatter("Page", nil, "Content")
      assert result =~ "position: 0"
    end

    test "handles empty content" do
      result = WikiExport.encode_frontmatter("Page", 0, "")
      assert result =~ "title: Page"
      assert result =~ "position: 0"
    end
  end

  describe "build_entries/2" do
    test "builds flat entries for leaf nodes" do
      tree = [
        %{
          document: %{slug: "leaf-page", title: "Leaf", position: 0, content: "Body"},
          children: []
        }
      ]

      entries = WikiExport.build_entries(tree, "")
      assert [{path, content}] = entries
      assert to_string(path) == "leaf-page.md"
      assert content =~ "title: Leaf"
      assert content =~ "Body"
    end

    test "builds nested entries for nodes with children" do
      tree = [
        %{
          document: %{slug: "parent", title: "Parent", position: 0, content: "Parent body"},
          children: [
            %{
              document: %{slug: "child", title: "Child", position: 0, content: "Child body"},
              children: []
            }
          ]
        }
      ]

      entries = WikiExport.build_entries(tree, "")
      paths = Enum.map(entries, fn {path, _} -> to_string(path) end)

      assert "parent/parent.md" in paths
      assert "parent/children/child.md" in paths
    end
  end

  describe "slug sanitization in build_entries" do
    test "sanitizes path traversal in slugs" do
      tree = [
        %{
          document: %{slug: "../etc/passwd", title: "Evil", position: 0, content: "body"},
          children: []
        }
      ]

      entries = WikiExport.build_entries(tree, "")
      [{path, _}] = entries
      path_str = to_string(path)

      refute path_str =~ ".."
      refute path_str =~ "/"
    end

    test "sanitizes backslashes and null bytes in slugs" do
      tree = [
        %{
          document: %{slug: "foo\\bar\0baz", title: "Evil", position: 0, content: "body"},
          children: []
        }
      ]

      entries = WikiExport.build_entries(tree, "")
      [{path, _}] = entries
      path_str = to_string(path)

      refute path_str =~ "\\"
      refute path_str =~ "\0"
    end

    test "handles nil slug" do
      tree = [
        %{
          document: %{slug: nil, title: "No Slug", position: 0, content: "body"},
          children: []
        }
      ]

      entries = WikiExport.build_entries(tree, "")
      [{path, _}] = entries
      assert to_string(path) == "untitled.md"
    end

    test "handles slug that becomes empty after sanitization" do
      tree = [
        %{
          document: %{slug: ".", title: "Dot", position: 0, content: "body"},
          children: []
        }
      ]

      entries = WikiExport.build_entries(tree, "")
      [{path, _}] = entries
      assert to_string(path) == "untitled.md"
    end
  end

  describe "yaml_escape via encode_frontmatter" do
    test "escapes titles with special YAML characters" do
      entries =
        WikiExport.build_entries(
          [
            %{
              document: %{
                slug: "special",
                title: "Title: With Colon",
                position: 0,
                content: "body"
              },
              children: []
            }
          ],
          ""
        )

      {_path, content} = hd(entries)
      # The title should be quoted because it contains a colon
      assert content =~ ~s("Title: With Colon")
    end
  end
end
