defmodule Liteskill.DataSourcesTest do
  use Liteskill.DataCase, async: true

  alias Liteskill.DataSources

  setup do
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

    %{owner: owner, other: other}
  end

  # --- Sources ---

  describe "list_sources/1" do
    test "includes built-in Wiki source", %{owner: owner} do
      sources = DataSources.list_sources(owner.id)

      wiki = Enum.find(sources, &(&1.id == "builtin:wiki"))
      assert wiki
      assert wiki.name == "Wiki"
      assert wiki.builtin == true
    end

    test "includes user's own DB sources", %{owner: owner} do
      {:ok, source} =
        DataSources.create_source(%{name: "My Source", source_type: "manual"}, owner.id)

      sources = DataSources.list_sources(owner.id)
      assert Enum.any?(sources, &(&1.id == source.id))
    end

    test "does not include other users' sources", %{owner: owner, other: other} do
      {:ok, _source} =
        DataSources.create_source(%{name: "Other Source", source_type: "manual"}, other.id)

      sources = DataSources.list_sources(owner.id)
      db_sources = Enum.reject(sources, &Map.get(&1, :builtin, false))
      assert db_sources == []
    end
  end

  describe "get_source/2" do
    test "returns builtin source by builtin ID", %{owner: owner} do
      assert {:ok, source} = DataSources.get_source("builtin:wiki", owner.id)
      assert source.name == "Wiki"
      assert source.builtin == true
    end

    test "returns :not_found for unknown builtin ID", %{owner: owner} do
      assert {:error, :not_found} = DataSources.get_source("builtin:unknown", owner.id)
    end

    test "returns DB source by UUID", %{owner: owner} do
      {:ok, created} =
        DataSources.create_source(%{name: "My Source", source_type: "manual"}, owner.id)

      assert {:ok, source} = DataSources.get_source(created.id, owner.id)
      assert source.id == created.id
    end

    test "returns :not_found for other user's source", %{owner: owner, other: other} do
      {:ok, source} =
        DataSources.create_source(%{name: "Other Source", source_type: "manual"}, other.id)

      assert {:error, :not_found} = DataSources.get_source(source.id, owner.id)
    end

    test "returns :not_found for nonexistent UUID", %{owner: owner} do
      assert {:error, :not_found} =
               DataSources.get_source(Ecto.UUID.generate(), owner.id)
    end
  end

  describe "create_source/2" do
    test "creates source with valid attrs", %{owner: owner} do
      attrs = %{name: "Test Source", source_type: "manual", description: "A test"}

      assert {:ok, source} = DataSources.create_source(attrs, owner.id)
      assert source.name == "Test Source"
      assert source.source_type == "manual"
      assert source.description == "A test"
      assert source.user_id == owner.id
    end

    test "fails without required name", %{owner: owner} do
      assert {:error, changeset} =
               DataSources.create_source(%{source_type: "manual"}, owner.id)

      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "fails without required source_type", %{owner: owner} do
      assert {:error, changeset} =
               DataSources.create_source(%{name: "Test"}, owner.id)

      assert %{source_type: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "delete_source/2" do
    test "deletes own DB source", %{owner: owner} do
      {:ok, source} =
        DataSources.create_source(%{name: "To Delete", source_type: "manual"}, owner.id)

      assert {:ok, _} = DataSources.delete_source(source.id, owner.id)
      assert {:error, :not_found} = DataSources.get_source(source.id, owner.id)
    end

    test "returns :cannot_delete_builtin for builtin source", %{owner: owner} do
      assert {:error, :cannot_delete_builtin} =
               DataSources.delete_source("builtin:wiki", owner.id)
    end

    test "returns :not_found for other user's source", %{owner: owner, other: other} do
      {:ok, source} =
        DataSources.create_source(%{name: "Other", source_type: "manual"}, other.id)

      assert {:error, :not_found} = DataSources.delete_source(source.id, owner.id)
    end
  end

  describe "update_source/3" do
    test "updates own DB source metadata", %{owner: owner} do
      {:ok, source} =
        DataSources.create_source(%{name: "My Source", source_type: "github"}, owner.id)

      metadata = %{"personal_access_token" => "ghp_test", "repository" => "owner/repo"}

      assert {:ok, updated} =
               DataSources.update_source(source.id, %{metadata: metadata}, owner.id)

      assert updated.metadata == metadata
    end

    test "returns :not_found for other user's source", %{owner: owner, other: other} do
      {:ok, source} =
        DataSources.create_source(%{name: "Other Source", source_type: "github"}, other.id)

      assert {:error, :not_found} =
               DataSources.update_source(source.id, %{metadata: %{"key" => "val"}}, owner.id)
    end

    test "returns :cannot_update_builtin for builtin source", %{owner: owner} do
      assert {:error, :cannot_update_builtin} =
               DataSources.update_source("builtin:wiki", %{metadata: %{}}, owner.id)
    end

    test "returns :not_found for nonexistent source", %{owner: owner} do
      assert {:error, :not_found} =
               DataSources.update_source(Ecto.UUID.generate(), %{metadata: %{}}, owner.id)
    end
  end

  # --- Documents ---

  describe "create_document/3" do
    test "creates document with valid attrs", %{owner: owner} do
      attrs = %{title: "My Page", content: "# Hello"}

      assert {:ok, doc} = DataSources.create_document("builtin:wiki", attrs, owner.id)
      assert doc.title == "My Page"
      assert doc.content == "# Hello"
      assert doc.source_ref == "builtin:wiki"
      assert doc.user_id == owner.id
      assert doc.content_type == "markdown"
    end

    test "auto-generates slug from title", %{owner: owner} do
      attrs = %{title: "Hello World Page"}

      assert {:ok, doc} = DataSources.create_document("builtin:wiki", attrs, owner.id)
      assert doc.slug == "hello-world-page"
    end

    test "uses provided slug when given", %{owner: owner} do
      attrs = %{title: "My Page", slug: "custom-slug"}

      assert {:ok, doc} = DataSources.create_document("builtin:wiki", attrs, owner.id)
      assert doc.slug == "custom-slug"
    end

    test "enforces unique slug per source_ref", %{owner: owner} do
      attrs = %{title: "Same Title"}

      assert {:ok, _} = DataSources.create_document("builtin:wiki", attrs, owner.id)
      assert {:error, changeset} = DataSources.create_document("builtin:wiki", attrs, owner.id)
      assert %{source_ref: ["has already been taken"]} = errors_on(changeset)
    end

    test "allows same slug in different sources", %{owner: owner} do
      attrs = %{title: "Same Title"}

      assert {:ok, _} = DataSources.create_document("builtin:wiki", attrs, owner.id)
      assert {:ok, _} = DataSources.create_document("other-source", attrs, owner.id)
    end

    test "fails without required title", %{owner: owner} do
      assert {:error, changeset} =
               DataSources.create_document("builtin:wiki", %{content: "body"}, owner.id)

      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates content_type inclusion", %{owner: owner} do
      attrs = %{title: "Test", content_type: "invalid"}

      assert {:error, changeset} =
               DataSources.create_document("builtin:wiki", attrs, owner.id)

      assert %{content_type: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "list_documents/2" do
    test "lists user's documents for a source_ref", %{owner: owner} do
      {:ok, _doc1} =
        DataSources.create_document("builtin:wiki", %{title: "Page 1"}, owner.id)

      {:ok, _doc2} =
        DataSources.create_document("builtin:wiki", %{title: "Page 2"}, owner.id)

      docs = DataSources.list_documents("builtin:wiki", owner.id)
      assert length(docs) == 2
    end

    test "does not include other users' documents", %{owner: owner, other: other} do
      {:ok, _} = DataSources.create_document("builtin:wiki", %{title: "Owner Page"}, owner.id)
      {:ok, _} = DataSources.create_document("builtin:wiki", %{title: "Other Page"}, other.id)

      docs = DataSources.list_documents("builtin:wiki", owner.id)
      assert length(docs) == 1
      assert hd(docs).title == "Owner Page"
    end

    test "does not include documents from other sources", %{owner: owner} do
      {:ok, _} = DataSources.create_document("builtin:wiki", %{title: "Wiki Page"}, owner.id)
      {:ok, _} = DataSources.create_document("other-source", %{title: "Other Page"}, owner.id)

      docs = DataSources.list_documents("builtin:wiki", owner.id)
      assert length(docs) == 1
    end

    test "ordered by updated_at desc", %{owner: owner} do
      {:ok, _doc1} =
        DataSources.create_document("builtin:wiki", %{title: "First"}, owner.id)

      {:ok, _doc2} =
        DataSources.create_document("builtin:wiki", %{title: "Second"}, owner.id)

      docs = DataSources.list_documents("builtin:wiki", owner.id)
      assert length(docs) == 2
      # Both returned, most recently updated first (or same timestamp)
      assert Enum.map(docs, & &1.updated_at) == Enum.sort(Enum.map(docs, & &1.updated_at), :desc)
    end
  end

  describe "get_document/2" do
    test "returns own document", %{owner: owner} do
      {:ok, created} =
        DataSources.create_document("builtin:wiki", %{title: "My Page"}, owner.id)

      assert {:ok, doc} = DataSources.get_document(created.id, owner.id)
      assert doc.id == created.id
    end

    test "returns :not_found for other user's document", %{owner: owner, other: other} do
      {:ok, doc} =
        DataSources.create_document("builtin:wiki", %{title: "Other Page"}, other.id)

      assert {:error, :not_found} = DataSources.get_document(doc.id, owner.id)
    end

    test "returns :not_found for nonexistent ID", %{owner: owner} do
      assert {:error, :not_found} = DataSources.get_document(Ecto.UUID.generate(), owner.id)
    end
  end

  describe "get_document_by_slug/2" do
    test "returns document by source_ref + slug", %{owner: owner} do
      {:ok, created} =
        DataSources.create_document("builtin:wiki", %{title: "My Page"}, owner.id)

      assert {:ok, doc} = DataSources.get_document_by_slug("builtin:wiki", created.slug)
      assert doc.id == created.id
    end

    test "returns :not_found for nonexistent slug" do
      assert {:error, :not_found} =
               DataSources.get_document_by_slug("builtin:wiki", "nonexistent")
    end
  end

  describe "update_document/3" do
    test "updates own document content", %{owner: owner} do
      {:ok, doc} =
        DataSources.create_document("builtin:wiki", %{title: "Original"}, owner.id)

      assert {:ok, updated} =
               DataSources.update_document(doc.id, %{title: "Updated"}, owner.id)

      assert updated.title == "Updated"
    end

    test "returns :not_found for other user's document", %{owner: owner, other: other} do
      {:ok, doc} =
        DataSources.create_document("builtin:wiki", %{title: "Other"}, other.id)

      assert {:error, :not_found} =
               DataSources.update_document(doc.id, %{title: "Hacked"}, owner.id)
    end
  end

  describe "delete_document/2" do
    test "deletes own document", %{owner: owner} do
      {:ok, doc} =
        DataSources.create_document("builtin:wiki", %{title: "To Delete"}, owner.id)

      assert {:ok, _} = DataSources.delete_document(doc.id, owner.id)
      assert {:error, :not_found} = DataSources.get_document(doc.id, owner.id)
    end

    test "returns :not_found for other user's document", %{owner: owner, other: other} do
      {:ok, doc} =
        DataSources.create_document("builtin:wiki", %{title: "Other"}, other.id)

      assert {:error, :not_found} = DataSources.delete_document(doc.id, owner.id)
    end
  end

  describe "list_documents_paginated/3" do
    test "returns paginated results", %{owner: owner} do
      for i <- 1..25 do
        {:ok, _} =
          DataSources.create_document("builtin:wiki", %{title: "Page #{i}"}, owner.id)
      end

      result = DataSources.list_documents_paginated("builtin:wiki", owner.id)
      assert length(result.documents) == 20
      assert result.page == 1
      assert result.total == 25
      assert result.total_pages == 2
    end

    test "returns second page", %{owner: owner} do
      for i <- 1..25 do
        {:ok, _} =
          DataSources.create_document("builtin:wiki", %{title: "Page #{i}"}, owner.id)
      end

      result = DataSources.list_documents_paginated("builtin:wiki", owner.id, page: 2)
      assert length(result.documents) == 5
      assert result.page == 2
    end

    test "custom page_size", %{owner: owner} do
      for i <- 1..5 do
        {:ok, _} =
          DataSources.create_document("builtin:wiki", %{title: "Page #{i}"}, owner.id)
      end

      result =
        DataSources.list_documents_paginated("builtin:wiki", owner.id, page_size: 2)

      assert length(result.documents) == 2
      assert result.total_pages == 3
    end

    test "filters by search term in title", %{owner: owner} do
      {:ok, _} =
        DataSources.create_document("builtin:wiki", %{title: "Getting Started"}, owner.id)

      {:ok, _} =
        DataSources.create_document(
          "builtin:wiki",
          %{title: "API Reference", slug: "api-ref"},
          owner.id
        )

      result =
        DataSources.list_documents_paginated("builtin:wiki", owner.id, search: "getting")

      assert length(result.documents) == 1
      assert hd(result.documents).title == "Getting Started"
    end

    test "filters by search term in content", %{owner: owner} do
      {:ok, _} =
        DataSources.create_document(
          "builtin:wiki",
          %{title: "Page A", content: "This has special keyword"},
          owner.id
        )

      {:ok, _} =
        DataSources.create_document(
          "builtin:wiki",
          %{title: "Page B", content: "Nothing here", slug: "page-b"},
          owner.id
        )

      result =
        DataSources.list_documents_paginated("builtin:wiki", owner.id, search: "special")

      assert length(result.documents) == 1
      assert hd(result.documents).title == "Page A"
    end

    test "empty search returns all", %{owner: owner} do
      {:ok, _} = DataSources.create_document("builtin:wiki", %{title: "Page 1"}, owner.id)

      result = DataSources.list_documents_paginated("builtin:wiki", owner.id, search: "")
      assert result.total == 1
    end

    test "returns total_pages of 1 when empty", %{owner: owner} do
      result = DataSources.list_documents_paginated("builtin:wiki", owner.id)
      assert result.total_pages == 1
      assert result.total == 0
    end

    test "scoped to user_id", %{owner: owner, other: other} do
      {:ok, _} = DataSources.create_document("builtin:wiki", %{title: "Owner"}, owner.id)
      {:ok, _} = DataSources.create_document("builtin:wiki", %{title: "Other"}, other.id)

      result = DataSources.list_documents_paginated("builtin:wiki", owner.id)
      assert result.total == 1
      assert hd(result.documents).title == "Owner"
    end
  end

  describe "document_count/1" do
    test "returns count of documents for source_ref", %{owner: owner} do
      {:ok, _} = DataSources.create_document("builtin:wiki", %{title: "Page 1"}, owner.id)
      {:ok, _} = DataSources.create_document("builtin:wiki", %{title: "Page 2"}, owner.id)

      assert DataSources.document_count("builtin:wiki") == 2
    end

    test "returns 0 for source_ref with no documents" do
      assert DataSources.document_count("nonexistent") == 0
    end
  end

  # --- Document Tree & Nesting ---

  describe "document_tree/2" do
    test "returns flat tree for root-only documents", %{owner: owner} do
      {:ok, _} = DataSources.create_document("builtin:wiki", %{title: "Page 1"}, owner.id)
      {:ok, _} = DataSources.create_document("builtin:wiki", %{title: "Page 2"}, owner.id)

      tree = DataSources.document_tree("builtin:wiki", owner.id)
      assert length(tree) == 2
      assert Enum.all?(tree, fn node -> node.children == [] end)
    end

    test "returns nested tree with children", %{owner: owner} do
      {:ok, parent} =
        DataSources.create_document("builtin:wiki", %{title: "Parent"}, owner.id)

      {:ok, _child} =
        DataSources.create_child_document(
          "builtin:wiki",
          parent.id,
          %{title: "Child"},
          owner.id
        )

      tree = DataSources.document_tree("builtin:wiki", owner.id)
      assert length(tree) == 1
      assert hd(tree).document.title == "Parent"
      assert length(hd(tree).children) == 1
      assert hd(hd(tree).children).document.title == "Child"
    end

    test "scoped to user_id", %{owner: owner, other: other} do
      {:ok, _} = DataSources.create_document("builtin:wiki", %{title: "Owner"}, owner.id)
      {:ok, _} = DataSources.create_document("builtin:wiki", %{title: "Other"}, other.id)

      tree = DataSources.document_tree("builtin:wiki", owner.id)
      assert length(tree) == 1
      assert hd(tree).document.title == "Owner"
    end
  end

  describe "create_child_document/4" do
    test "creates child with correct parent and position", %{owner: owner} do
      {:ok, parent} =
        DataSources.create_document("builtin:wiki", %{title: "Parent"}, owner.id)

      {:ok, child1} =
        DataSources.create_child_document(
          "builtin:wiki",
          parent.id,
          %{title: "Child 1"},
          owner.id
        )

      {:ok, child2} =
        DataSources.create_child_document(
          "builtin:wiki",
          parent.id,
          %{title: "Child 2"},
          owner.id
        )

      assert child1.parent_document_id == parent.id
      assert child1.position == 0
      assert child2.position == 1
    end

    test "creates root-level child with nil parent_id", %{owner: owner} do
      {:ok, root1} =
        DataSources.create_child_document(
          "builtin:wiki",
          nil,
          %{title: "Root 1"},
          owner.id
        )

      {:ok, root2} =
        DataSources.create_child_document(
          "builtin:wiki",
          nil,
          %{title: "Root 2"},
          owner.id
        )

      assert root1.parent_document_id == nil
      assert root1.position == 0
      assert root2.position == 1
    end
  end

  describe "list_documents_paginated/3 with parent_id filter" do
    test "returns only root documents when parent_id is nil", %{owner: owner} do
      {:ok, parent} =
        DataSources.create_document("builtin:wiki", %{title: "Root"}, owner.id)

      {:ok, _child} =
        DataSources.create_child_document(
          "builtin:wiki",
          parent.id,
          %{title: "Child"},
          owner.id
        )

      result = DataSources.list_documents_paginated("builtin:wiki", owner.id, parent_id: nil)
      assert result.total == 1
      assert hd(result.documents).title == "Root"
    end

    test "returns all documents when parent_id is :unset", %{owner: owner} do
      {:ok, parent} =
        DataSources.create_document("builtin:wiki", %{title: "Root"}, owner.id)

      {:ok, _child} =
        DataSources.create_child_document(
          "builtin:wiki",
          parent.id,
          %{title: "Child"},
          owner.id
        )

      result = DataSources.list_documents_paginated("builtin:wiki", owner.id)
      assert result.total == 2
    end

    test "returns children of a specific parent", %{owner: owner} do
      {:ok, parent} =
        DataSources.create_document("builtin:wiki", %{title: "Root"}, owner.id)

      {:ok, child} =
        DataSources.create_child_document(
          "builtin:wiki",
          parent.id,
          %{title: "Child"},
          owner.id
        )

      result =
        DataSources.list_documents_paginated("builtin:wiki", owner.id, parent_id: parent.id)

      assert result.total == 1
      assert hd(result.documents).id == child.id
    end
  end

  describe "space_tree/3" do
    test "returns children of the given space", %{owner: owner} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "Space"}, owner.id)

      {:ok, _child} =
        DataSources.create_child_document(
          "builtin:wiki",
          space.id,
          %{title: "Page"},
          owner.id
        )

      {:ok, _other_space} =
        DataSources.create_document("builtin:wiki", %{title: "Other Space"}, owner.id)

      tree = DataSources.space_tree("builtin:wiki", space.id, owner.id)
      assert length(tree) == 1
      assert hd(tree).document.title == "Page"
    end

    test "returns empty list for space with no children", %{owner: owner} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "Empty"}, owner.id)

      assert DataSources.space_tree("builtin:wiki", space.id, owner.id) == []
    end

    test "returns nested children", %{owner: owner} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "Space"}, owner.id)

      {:ok, child} =
        DataSources.create_child_document(
          "builtin:wiki",
          space.id,
          %{title: "Child"},
          owner.id
        )

      {:ok, _grandchild} =
        DataSources.create_child_document(
          "builtin:wiki",
          child.id,
          %{title: "Grandchild"},
          owner.id
        )

      tree = DataSources.space_tree("builtin:wiki", space.id, owner.id)
      assert length(tree) == 1
      assert length(hd(tree).children) == 1
      assert hd(hd(tree).children).document.title == "Grandchild"
    end
  end

  describe "find_root_ancestor/2" do
    test "returns the document itself if it is a root", %{owner: owner} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "Space"}, owner.id)

      assert {:ok, root} = DataSources.find_root_ancestor(space.id, owner.id)
      assert root.id == space.id
    end

    test "walks up to the root from a child", %{owner: owner} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "Space"}, owner.id)

      {:ok, child} =
        DataSources.create_child_document(
          "builtin:wiki",
          space.id,
          %{title: "Child"},
          owner.id
        )

      assert {:ok, root} = DataSources.find_root_ancestor(child.id, owner.id)
      assert root.id == space.id
    end

    test "walks up from a grandchild", %{owner: owner} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "Space"}, owner.id)

      {:ok, child} =
        DataSources.create_child_document(
          "builtin:wiki",
          space.id,
          %{title: "Child"},
          owner.id
        )

      {:ok, grandchild} =
        DataSources.create_child_document(
          "builtin:wiki",
          child.id,
          %{title: "GC"},
          owner.id
        )

      assert {:ok, root} = DataSources.find_root_ancestor(grandchild.id, owner.id)
      assert root.id == space.id
    end

    test "returns error for nonexistent document", %{owner: owner} do
      assert {:error, :not_found} =
               DataSources.find_root_ancestor(Ecto.UUID.generate(), owner.id)
    end
  end

  describe "export_report_to_wiki/3" do
    test "exports report as a single wiki page with flattened content", %{owner: owner} do
      {:ok, report} = Liteskill.Reports.create_report(owner.id, "Test Report")

      {:ok, _} =
        Liteskill.Reports.upsert_section(report.id, owner.id, "Chapter 1", "Content 1")

      {:ok, _} =
        Liteskill.Reports.upsert_section(
          report.id,
          owner.id,
          "Chapter 1 > Sub 1",
          "Sub content"
        )

      assert {:ok, doc} =
               DataSources.export_report_to_wiki(report.id, owner.id, title: "My Wiki Export")

      assert doc.title == "My Wiki Export"
      assert doc.source_ref == "builtin:wiki"
      assert doc.content =~ "Chapter 1"
      assert doc.content =~ "Content 1"
      assert doc.content =~ "Sub 1"
      assert doc.content =~ "Sub content"
      assert is_nil(doc.parent_document_id)
    end

    test "exports report under a parent wiki page", %{owner: owner} do
      {:ok, report} = Liteskill.Reports.create_report(owner.id, "Test Report")

      {:ok, _} =
        Liteskill.Reports.upsert_section(report.id, owner.id, "Section A", "Some content")

      {:ok, parent} =
        DataSources.create_document("builtin:wiki", %{title: "Parent Page"}, owner.id)

      assert {:ok, doc} =
               DataSources.export_report_to_wiki(report.id, owner.id,
                 title: "Child Export",
                 parent_id: parent.id
               )

      assert doc.title == "Child Export"
      assert doc.parent_document_id == parent.id
      assert doc.content =~ "Section A"
    end

    test "uses report title when no title given", %{owner: owner} do
      {:ok, report} = Liteskill.Reports.create_report(owner.id, "My Report Title")

      assert {:ok, doc} = DataSources.export_report_to_wiki(report.id, owner.id)

      assert doc.title == "My Report Title"
    end

    test "returns error for nonexistent report", %{owner: owner} do
      assert {:error, :not_found} =
               DataSources.export_report_to_wiki(Ecto.UUID.generate(), owner.id, title: "Title")
    end

    test "returns error when document creation fails (duplicate slug)", %{owner: owner} do
      {:ok, report} = Liteskill.Reports.create_report(owner.id, "Dup Report")

      # Pre-create a wiki doc with the same slug so the export hits a unique constraint
      {:ok, _} =
        DataSources.create_document("builtin:wiki", %{title: "Dup Report"}, owner.id)

      assert {:error, %Ecto.Changeset{}} =
               DataSources.export_report_to_wiki(report.id, owner.id)
    end
  end
end
