defmodule Liteskill.DataSourcesTest do
  use Liteskill.DataCase, async: false
  use Oban.Testing, repo: Liteskill.Repo

  alias Liteskill.Authorization
  alias Liteskill.Authorization.EntityAcl
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

  # --- Config & Types ---

  describe "config_fields_for/1" do
    test "returns fields for known source type" do
      fields = DataSources.config_fields_for("github")
      assert fields != []
      assert Enum.all?(fields, &is_map/1)
      assert Enum.all?(fields, &Map.has_key?(&1, :key))
      assert Enum.all?(fields, &Map.has_key?(&1, :label))
      assert Enum.all?(fields, &Map.has_key?(&1, :type))
    end

    test "returns empty list for unknown source type" do
      assert DataSources.config_fields_for("nonexistent") == []
    end

    test "all available source types have config fields" do
      for st <- DataSources.available_source_types() do
        assert DataSources.config_fields_for(st.source_type) != [],
               "#{st.source_type} should have config fields"
      end
    end
  end

  describe "available_source_types/0" do
    test "returns a list" do
      types = DataSources.available_source_types()
      assert [_ | _] = types
    end

    test "each entry has name and source_type" do
      for t <- DataSources.available_source_types() do
        assert Map.has_key?(t, :name)
        assert Map.has_key?(t, :source_type)
      end
    end

    test "source_types match config_fields_for keys" do
      for t <- DataSources.available_source_types() do
        assert DataSources.config_fields_for(t.source_type) != []
      end
    end
  end

  describe "validate_metadata/2" do
    test "filters unknown keys" do
      metadata = %{"personal_access_token" => "ghp_x", "repository" => "o/r", "extra" => "bad"}
      assert {:ok, filtered} = DataSources.validate_metadata("github", metadata)
      assert Map.has_key?(filtered, "personal_access_token")
      assert Map.has_key?(filtered, "repository")
      refute Map.has_key?(filtered, "extra")
    end

    test "returns error for unknown source type" do
      assert {:error, :unknown_source_type} =
               DataSources.validate_metadata("nonexistent", %{"key" => "val"})
    end

    test "handles empty metadata" do
      assert {:ok, %{}} = DataSources.validate_metadata("github", %{})
    end

    test "passes through all valid keys" do
      metadata = %{"personal_access_token" => "ghp_x", "repository" => "o/r"}
      assert {:ok, ^metadata} = DataSources.validate_metadata("github", metadata)
    end
  end

  describe "list_sources_with_counts/1" do
    test "returns sources with document_count", %{owner: owner} do
      {:ok, _source} =
        DataSources.create_source(%{name: "Counted", source_type: "manual"}, owner.id)

      sources = DataSources.list_sources_with_counts(owner.id)
      assert is_list(sources)
      assert Enum.all?(sources, &Map.has_key?(&1, :document_count))
    end

    test "includes builtin sources", %{owner: owner} do
      sources = DataSources.list_sources_with_counts(owner.id)
      assert Enum.any?(sources, &(Map.get(&1, :builtin) == true))
    end

    test "document_count reflects actual documents", %{owner: owner} do
      {:ok, source} =
        DataSources.create_source(%{name: "With Docs", source_type: "manual"}, owner.id)

      {:ok, _} =
        DataSources.create_document(source.id, %{title: "Doc 1"}, owner.id)

      {:ok, _} =
        DataSources.create_document(source.id, %{title: "Doc 2"}, owner.id)

      sources = DataSources.list_sources_with_counts(owner.id)
      counted = Enum.find(sources, &(&1.id == source.id))
      assert counted.document_count == 2
    end
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

    test "includes sources shared via ACL", %{owner: owner, other: other} do
      {:ok, source} =
        DataSources.create_source(%{name: "Shared Source", source_type: "manual"}, other.id)

      {:ok, _} =
        Authorization.grant_access("source", source.id, other.id, owner.id, "viewer")

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

    test "returns source shared via ACL", %{owner: owner, other: other} do
      {:ok, source} =
        DataSources.create_source(%{name: "Shared", source_type: "manual"}, other.id)

      {:ok, _} =
        Authorization.grant_access("source", source.id, other.id, owner.id, "viewer")

      assert {:ok, found} = DataSources.get_source(source.id, owner.id)
      assert found.id == source.id
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

    test "creates owner ACL", %{owner: owner} do
      {:ok, source} =
        DataSources.create_source(%{name: "ACL Test", source_type: "manual"}, owner.id)

      acl =
        Repo.one!(
          from(a in EntityAcl,
            where: a.entity_type == "source" and a.entity_id == ^source.id
          )
        )

      assert acl.user_id == owner.id
      assert acl.role == "owner"
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

  describe "get_source_by_type/2" do
    test "returns source when it exists", %{owner: owner} do
      {:ok, source} =
        DataSources.create_source(
          %{name: "My GitHub", source_type: "github", description: ""},
          owner.id
        )

      found = DataSources.get_source_by_type(owner.id, "github")
      assert found.id == source.id
    end

    test "returns nil when no source of that type exists", %{owner: owner} do
      assert DataSources.get_source_by_type(owner.id, "sharepoint") == nil
    end

    test "does not return other user's source", %{owner: owner, other: other} do
      {:ok, _} =
        DataSources.create_source(
          %{name: "Owner GitHub", source_type: "github", description: ""},
          owner.id
        )

      assert DataSources.get_source_by_type(other.id, "github") == nil
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

    test "cascade-deletes associated documents", %{owner: owner} do
      {:ok, source} =
        DataSources.create_source(%{name: "With Docs", source_type: "manual"}, owner.id)

      {:ok, _} = DataSources.create_document(source.id, %{title: "Doc 1"}, owner.id)
      {:ok, _} = DataSources.create_document(source.id, %{title: "Doc 2"}, owner.id)

      assert DataSources.document_count(source.id) == 2
      assert {:ok, _} = DataSources.delete_source(source.id, owner.id)
      assert DataSources.document_count(source.id) == 0
    end

    test "non-owner cannot delete another user's source", %{owner: owner, other: other} do
      {:ok, source} =
        DataSources.create_source(%{name: "Other's Source", source_type: "manual"}, other.id)

      assert {:error, :not_found} = DataSources.delete_source(source.id, owner.id)
    end

    test "cannot delete builtin source", %{owner: owner} do
      assert {:error, :cannot_delete_builtin} =
               DataSources.delete_source("builtin:wiki", owner.id)
    end

    test "returns :not_found for nonexistent source", %{owner: owner} do
      assert {:error, :not_found} =
               DataSources.delete_source(Ecto.UUID.generate(), owner.id)
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

    test "enforces unique slug for root documents per source_ref", %{owner: owner} do
      attrs = %{title: "Same Title"}

      assert {:ok, _} = DataSources.create_document("builtin:wiki", attrs, owner.id)
      assert {:error, changeset} = DataSources.create_document("builtin:wiki", attrs, owner.id)
      assert %{source_ref: ["a space with this title already exists"]} = errors_on(changeset)
    end

    test "allows same slug in different sources", %{owner: owner} do
      attrs = %{title: "Same Title"}

      assert {:ok, _} = DataSources.create_document("builtin:wiki", attrs, owner.id)
      assert {:ok, _} = DataSources.create_document("other-source", attrs, owner.id)
    end

    test "allows same slug for child pages in different parents", %{owner: owner} do
      {:ok, space_a} = DataSources.create_document("builtin:wiki", %{title: "Space A"}, owner.id)
      {:ok, space_b} = DataSources.create_document("builtin:wiki", %{title: "Space B"}, owner.id)

      attrs = %{title: "Getting Started"}

      assert {:ok, _} =
               DataSources.create_child_document("builtin:wiki", space_a.id, attrs, owner.id)

      assert {:ok, _} =
               DataSources.create_child_document("builtin:wiki", space_b.id, attrs, owner.id)
    end

    test "enforces unique slug for child pages within same parent", %{owner: owner} do
      {:ok, space} = DataSources.create_document("builtin:wiki", %{title: "My Space"}, owner.id)
      attrs = %{title: "Same Page"}

      assert {:ok, _} =
               DataSources.create_child_document("builtin:wiki", space.id, attrs, owner.id)

      assert {:error, changeset} =
               DataSources.create_child_document("builtin:wiki", space.id, attrs, owner.id)

      assert %{source_ref: ["a page with this title already exists in this space"]} =
               errors_on(changeset)
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

  # --- Upsert / Delete by External ID ---

  describe "upsert_document_by_external_id/4" do
    test "creates document when none exists", %{owner: owner} do
      {:ok, source} =
        DataSources.create_source(%{name: "upsert-test", source_type: "wiki"}, owner.id)

      attrs = %{title: "New Doc", content: "hello"}

      assert {:ok, :created, doc} =
               DataSources.upsert_document_by_external_id(
                 source.id,
                 "ext-1",
                 attrs,
                 owner.id
               )

      assert doc.title == "New Doc"
      assert doc.external_id == "ext-1"
    end

    test "returns unchanged when content_hash matches", %{owner: owner} do
      {:ok, source} =
        DataSources.create_source(%{name: "upsert-unchanged", source_type: "wiki"}, owner.id)

      attrs = %{title: "Doc", content: "same content"}

      {:ok, :created, _} =
        DataSources.upsert_document_by_external_id(source.id, "ext-2", attrs, owner.id)

      assert {:ok, :unchanged, _} =
               DataSources.upsert_document_by_external_id(source.id, "ext-2", attrs, owner.id)
    end

    test "updates document when content changes", %{owner: owner} do
      {:ok, source} =
        DataSources.create_source(%{name: "upsert-update", source_type: "wiki"}, owner.id)

      {:ok, :created, _} =
        DataSources.upsert_document_by_external_id(
          source.id,
          "ext-3",
          %{title: "Doc", content: "v1"},
          owner.id
        )

      assert {:ok, :updated, doc} =
               DataSources.upsert_document_by_external_id(
                 source.id,
                 "ext-3",
                 %{title: "Doc", content: "v2"},
                 owner.id
               )

      assert doc.content == "v2"
    end
  end

  # --- Wiki Space ACL ---

  describe "wiki space ACL - create_document auto-creates owner ACL" do
    test "creates owner ACL for new wiki space", %{owner: owner} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "ACL Space"}, owner.id)

      acl =
        Repo.one!(
          from(a in EntityAcl,
            where: a.entity_type == "wiki_space" and a.entity_id == ^space.id
          )
        )

      assert acl.user_id == owner.id
      assert acl.role == "owner"
    end

    test "does not create ACL for non-wiki documents", %{owner: owner} do
      {:ok, source} =
        DataSources.create_source(%{name: "Non Wiki", source_type: "manual"}, owner.id)

      {:ok, doc} =
        DataSources.create_document(source.id, %{title: "Not Wiki"}, owner.id)

      acl =
        Repo.one(
          from(a in EntityAcl,
            where: a.entity_type == "wiki_space" and a.entity_id == ^doc.id
          )
        )

      assert acl == nil
    end
  end

  describe "wiki space ACL - get_document" do
    test "returns doc for viewer ACL user", %{owner: owner, other: other} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "Shared Space"}, owner.id)

      {:ok, _} =
        Authorization.grant_access("wiki_space", space.id, owner.id, other.id, "viewer")

      assert {:ok, doc} = DataSources.get_document(space.id, other.id)
      assert doc.id == space.id
    end

    test "returns child doc for viewer ACL user", %{owner: owner, other: other} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "Space"}, owner.id)

      {:ok, child} =
        DataSources.create_child_document(
          "builtin:wiki",
          space.id,
          %{title: "Child Page"},
          owner.id
        )

      {:ok, _} =
        Authorization.grant_access("wiki_space", space.id, owner.id, other.id, "viewer")

      assert {:ok, doc} = DataSources.get_document(child.id, other.id)
      assert doc.id == child.id
    end

    test "returns :not_found for no-ACL user", %{owner: owner, other: other} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "Private Space"}, owner.id)

      assert {:error, :not_found} = DataSources.get_document(space.id, other.id)
    end
  end

  describe "wiki space ACL - get_document_with_role" do
    test "returns owner role for space owner", %{owner: owner} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "My Space"}, owner.id)

      assert {:ok, doc, "owner"} = DataSources.get_document_with_role(space.id, owner.id)
      assert doc.id == space.id
    end

    test "returns editor role for editor user", %{owner: owner, other: other} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "Editor Space"}, owner.id)

      {:ok, _} =
        Authorization.grant_access("wiki_space", space.id, owner.id, other.id, "editor")

      assert {:ok, _, "editor"} = DataSources.get_document_with_role(space.id, other.id)
    end

    test "returns viewer role for viewer user", %{owner: owner, other: other} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "Viewer Space"}, owner.id)

      {:ok, _} =
        Authorization.grant_access("wiki_space", space.id, owner.id, other.id, "viewer")

      assert {:ok, _, "viewer"} = DataSources.get_document_with_role(space.id, other.id)
    end

    test "returns :not_found for no-ACL user", %{owner: owner, other: other} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "Closed Space"}, owner.id)

      assert {:error, :not_found} = DataSources.get_document_with_role(space.id, other.id)
    end

    test "returns :not_found for nonexistent ID", %{owner: owner} do
      assert {:error, :not_found} =
               DataSources.get_document_with_role(Ecto.UUID.generate(), owner.id)
    end

    test "returns role for child doc via space ACL", %{owner: owner, other: other} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "Space"}, owner.id)

      {:ok, child} =
        DataSources.create_child_document(
          "builtin:wiki",
          space.id,
          %{title: "Child"},
          owner.id
        )

      {:ok, _} =
        Authorization.grant_access("wiki_space", space.id, owner.id, other.id, "manager")

      assert {:ok, _, "manager"} = DataSources.get_document_with_role(child.id, other.id)
    end
  end

  describe "wiki space ACL - list_documents_paginated" do
    test "includes shared spaces", %{owner: owner, other: other} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "Shared Space"}, owner.id)

      {:ok, _} =
        Authorization.grant_access("wiki_space", space.id, owner.id, other.id, "viewer")

      result = DataSources.list_documents_paginated("builtin:wiki", other.id, parent_id: nil)
      assert Enum.any?(result.documents, &(&1.id == space.id))
    end

    test "excludes unshared spaces", %{owner: owner, other: other} do
      {:ok, _space} =
        DataSources.create_document("builtin:wiki", %{title: "Hidden Space"}, owner.id)

      result = DataSources.list_documents_paginated("builtin:wiki", other.id, parent_id: nil)
      assert result.total == 0
    end
  end

  describe "wiki space ACL - space_tree" do
    test "returns tree for ACL-shared space", %{owner: owner, other: other} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "Shared"}, owner.id)

      {:ok, _child} =
        DataSources.create_child_document(
          "builtin:wiki",
          space.id,
          %{title: "Child"},
          owner.id
        )

      {:ok, _} =
        Authorization.grant_access("wiki_space", space.id, owner.id, other.id, "viewer")

      tree = DataSources.space_tree("builtin:wiki", space.id, other.id)
      assert length(tree) == 1
      assert hd(tree).document.title == "Child"
    end

    test "returns empty for unshared space", %{owner: owner, other: other} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "Private"}, owner.id)

      {:ok, _child} =
        DataSources.create_child_document(
          "builtin:wiki",
          space.id,
          %{title: "Child"},
          owner.id
        )

      assert DataSources.space_tree("builtin:wiki", space.id, other.id) == []
    end

    test "returns empty for nonexistent space", %{owner: owner} do
      assert DataSources.space_tree("builtin:wiki", Ecto.UUID.generate(), owner.id) == []
    end
  end

  describe "wiki space ACL - create_child_document" do
    test "editor can create child in shared space", %{owner: owner, other: other} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "Editor Space"}, owner.id)

      {:ok, _} =
        Authorization.grant_access("wiki_space", space.id, owner.id, other.id, "editor")

      assert {:ok, child} =
               DataSources.create_child_document(
                 "builtin:wiki",
                 space.id,
                 %{title: "New Page"},
                 other.id
               )

      # Child should have space owner's user_id
      assert child.user_id == owner.id
      assert child.parent_document_id == space.id
    end

    test "viewer cannot create child in shared space", %{owner: owner, other: other} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "Viewer Space"}, owner.id)

      {:ok, _} =
        Authorization.grant_access("wiki_space", space.id, owner.id, other.id, "viewer")

      assert {:error, :forbidden} =
               DataSources.create_child_document(
                 "builtin:wiki",
                 space.id,
                 %{title: "Denied"},
                 other.id
               )
    end

    test "no-ACL user cannot create child", %{owner: owner, other: other} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "No ACL Space"}, owner.id)

      assert {:error, _} =
               DataSources.create_child_document(
                 "builtin:wiki",
                 space.id,
                 %{title: "Denied"},
                 other.id
               )
    end
  end

  describe "wiki space ACL - update_document" do
    test "editor can update doc in shared space", %{owner: owner, other: other} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "Space"}, owner.id)

      {:ok, child} =
        DataSources.create_child_document(
          "builtin:wiki",
          space.id,
          %{title: "Page"},
          owner.id
        )

      {:ok, _} =
        Authorization.grant_access("wiki_space", space.id, owner.id, other.id, "editor")

      assert {:ok, updated} =
               DataSources.update_document(child.id, %{title: "Updated Page"}, other.id)

      assert updated.title == "Updated Page"
    end

    test "viewer cannot update doc in shared space", %{owner: owner, other: other} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "Space"}, owner.id)

      {:ok, child} =
        DataSources.create_child_document(
          "builtin:wiki",
          space.id,
          %{title: "Page"},
          owner.id
        )

      {:ok, _} =
        Authorization.grant_access("wiki_space", space.id, owner.id, other.id, "viewer")

      assert {:error, :not_found} =
               DataSources.update_document(child.id, %{title: "Denied"}, other.id)
    end
  end

  describe "wiki space ACL - delete_document" do
    test "manager can delete child page", %{owner: owner, other: other} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "Space"}, owner.id)

      {:ok, child} =
        DataSources.create_child_document(
          "builtin:wiki",
          space.id,
          %{title: "To Delete"},
          owner.id
        )

      {:ok, _} =
        Authorization.grant_access("wiki_space", space.id, owner.id, other.id, "manager")

      assert {:ok, _} = DataSources.delete_document(child.id, other.id)
    end

    test "editor cannot delete child page", %{owner: owner, other: other} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "Space"}, owner.id)

      {:ok, child} =
        DataSources.create_child_document(
          "builtin:wiki",
          space.id,
          %{title: "Protected"},
          owner.id
        )

      {:ok, _} =
        Authorization.grant_access("wiki_space", space.id, owner.id, other.id, "editor")

      assert {:error, :forbidden} = DataSources.delete_document(child.id, other.id)
    end

    test "only space owner can delete the space itself", %{owner: owner, other: other} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "Space"}, owner.id)

      {:ok, _} =
        Authorization.grant_access("wiki_space", space.id, owner.id, other.id, "manager")

      assert {:error, :forbidden} = DataSources.delete_document(space.id, other.id)
      assert {:ok, _} = DataSources.delete_document(space.id, owner.id)
    end
  end

  describe "non-wiki document access" do
    test "get_document returns :not_found for other user's non-wiki doc", %{
      owner: owner,
      other: other
    } do
      {:ok, source} =
        DataSources.create_source(%{name: "Manual", source_type: "manual"}, other.id)

      {:ok, doc} = DataSources.create_document(source.id, %{title: "Other's Doc"}, other.id)
      assert {:error, :not_found} = DataSources.get_document(doc.id, owner.id)
    end

    test "get_document_with_role returns :not_found for other user's non-wiki doc", %{
      owner: owner,
      other: other
    } do
      {:ok, source} =
        DataSources.create_source(%{name: "Manual", source_type: "manual"}, other.id)

      {:ok, doc} = DataSources.create_document(source.id, %{title: "Other's Doc"}, other.id)
      assert {:error, :not_found} = DataSources.get_document_with_role(doc.id, owner.id)
    end

    test "update_document returns :not_found for nonexistent ID", %{owner: owner} do
      assert {:error, :not_found} =
               DataSources.update_document(Ecto.UUID.generate(), %{title: "X"}, owner.id)
    end

    test "update_document returns :not_found for other user's non-wiki doc", %{
      owner: owner,
      other: other
    } do
      {:ok, source} =
        DataSources.create_source(%{name: "Manual", source_type: "manual"}, other.id)

      {:ok, doc} = DataSources.create_document(source.id, %{title: "Other's"}, other.id)

      assert {:error, :not_found} =
               DataSources.update_document(doc.id, %{title: "Hacked"}, owner.id)
    end

    test "delete_document returns :not_found for nonexistent ID", %{owner: owner} do
      assert {:error, :not_found} =
               DataSources.delete_document(Ecto.UUID.generate(), owner.id)
    end

    test "delete_document returns :not_found for other user's non-wiki doc", %{
      owner: owner,
      other: other
    } do
      {:ok, source} =
        DataSources.create_source(%{name: "Manual", source_type: "manual"}, other.id)

      {:ok, doc} = DataSources.create_document(source.id, %{title: "Other's"}, other.id)
      assert {:error, :not_found} = DataSources.delete_document(doc.id, owner.id)
    end

    test "list_documents_paginated for non-wiki source scoped to user_id", %{
      owner: owner,
      other: other
    } do
      {:ok, source} =
        DataSources.create_source(%{name: "Manual", source_type: "manual"}, owner.id)

      {:ok, _} = DataSources.create_document(source.id, %{title: "Mine"}, owner.id)
      {:ok, _} = DataSources.create_document(source.id, %{title: "Theirs"}, other.id)

      result = DataSources.list_documents_paginated(source.id, owner.id)
      assert result.total == 1
      assert hd(result.documents).title == "Mine"
    end
  end

  describe "wiki space ACL - delete_document no access" do
    test "no-ACL user gets :not_found for wiki child deletion", %{owner: owner, other: other} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "Space"}, owner.id)

      {:ok, child} =
        DataSources.create_child_document(
          "builtin:wiki",
          space.id,
          %{title: "Child"},
          owner.id
        )

      assert {:error, :not_found} = DataSources.delete_document(child.id, other.id)
    end

    test "no-ACL user gets :not_found for wiki space deletion", %{owner: owner, other: other} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "Space"}, owner.id)

      assert {:error, :not_found} = DataSources.delete_document(space.id, other.id)
    end
  end

  describe "wiki space ACL - find_root_ancestor" do
    test "works for shared wiki child doc", %{owner: owner, other: other} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "Shared Root"}, owner.id)

      {:ok, child} =
        DataSources.create_child_document(
          "builtin:wiki",
          space.id,
          %{title: "Child"},
          owner.id
        )

      {:ok, _} =
        Authorization.grant_access("wiki_space", space.id, owner.id, other.id, "viewer")

      assert {:ok, root} = DataSources.find_root_ancestor(child.id, other.id)
      assert root.id == space.id
    end

    test "returns not_found for unshared wiki doc", %{owner: owner, other: other} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "Private Root"}, owner.id)

      {:ok, child} =
        DataSources.create_child_document(
          "builtin:wiki",
          space.id,
          %{title: "Child"},
          owner.id
        )

      assert {:error, :not_found} = DataSources.find_root_ancestor(child.id, other.id)
    end
  end

  describe "get_space_id/1" do
    test "returns self ID for root space document", %{owner: owner} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "Space"}, owner.id)

      assert DataSources.get_space_id(space) == space.id
    end

    test "returns root ancestor ID for child document", %{owner: owner} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "Space"}, owner.id)

      {:ok, child} =
        DataSources.create_child_document(
          "builtin:wiki",
          space.id,
          %{title: "Child"},
          owner.id
        )

      assert DataSources.get_space_id(child) == space.id
    end
  end

  describe "delete_document_by_external_id/3" do
    test "deletes existing document", %{owner: owner} do
      {:ok, source} =
        DataSources.create_source(%{name: "del-test", source_type: "wiki"}, owner.id)

      {:ok, :created, _} =
        DataSources.upsert_document_by_external_id(
          source.id,
          "ext-del",
          %{title: "To Delete", content: "bye"},
          owner.id
        )

      assert {:ok, _} =
               DataSources.delete_document_by_external_id(source.id, "ext-del", owner.id)
    end

    test "returns not_found for missing document", %{owner: owner} do
      {:ok, source} =
        DataSources.create_source(%{name: "del-noop", source_type: "wiki"}, owner.id)

      assert {:ok, :not_found} =
               DataSources.delete_document_by_external_id(source.id, "nope", owner.id)
    end
  end

  describe "wiki sync enqueuing" do
    test "create_document with content enqueues wiki sync", %{owner: owner} do
      {:ok, doc} =
        DataSources.create_document(
          "builtin:wiki",
          %{title: "Sync Page", content: "Hello world"},
          owner.id
        )

      assert_enqueued(
        worker: Liteskill.Rag.WikiSyncWorker,
        args: %{"wiki_document_id" => doc.id, "action" => "upsert"}
      )
    end

    test "create_document without content does not enqueue", %{owner: owner} do
      {:ok, _doc} =
        DataSources.create_document("builtin:wiki", %{title: "Empty"}, owner.id)

      refute_enqueued(worker: Liteskill.Rag.WikiSyncWorker)
    end

    test "create_document for non-wiki source does not enqueue", %{owner: owner} do
      {:ok, _source} =
        DataSources.create_source(%{name: "test-src", source_type: "wiki"}, owner.id)

      {:ok, _doc} =
        DataSources.create_document(
          "test-src",
          %{title: "Non Wiki", content: "Hello"},
          owner.id
        )

      refute_enqueued(worker: Liteskill.Rag.WikiSyncWorker)
    end

    test "create_child_document with content enqueues wiki sync", %{owner: owner} do
      {:ok, space} =
        DataSources.create_document("builtin:wiki", %{title: "Space"}, owner.id)

      # Drain the enqueue from space creation (no content, should be none)
      Oban.drain_queue(queue: :rag_ingest)

      {:ok, child} =
        DataSources.create_child_document(
          "builtin:wiki",
          space.id,
          %{title: "Child", content: "Child content"},
          owner.id
        )

      assert_enqueued(
        worker: Liteskill.Rag.WikiSyncWorker,
        args: %{"wiki_document_id" => child.id, "action" => "upsert"}
      )
    end

    test "update_document of wiki doc enqueues upsert", %{owner: owner} do
      {:ok, doc} =
        DataSources.create_document("builtin:wiki", %{title: "Page"}, owner.id)

      {:ok, _updated} =
        DataSources.update_document(doc.id, %{content: "New content"}, owner.id)

      assert_enqueued(
        worker: Liteskill.Rag.WikiSyncWorker,
        args: %{"wiki_document_id" => doc.id, "action" => "upsert"}
      )
    end

    test "delete_document of wiki doc enqueues delete", %{owner: owner} do
      {:ok, doc} =
        DataSources.create_document("builtin:wiki", %{title: "Doomed"}, owner.id)

      {:ok, _} = DataSources.delete_document(doc.id, owner.id)

      assert_enqueued(
        worker: Liteskill.Rag.WikiSyncWorker,
        args: %{"wiki_document_id" => doc.id, "action" => "delete"}
      )
    end
  end

  describe "enqueue_index_source/2" do
    test "enqueues upsert jobs only for documents with content", %{owner: owner} do
      {:ok, with_content} =
        DataSources.create_document(
          "builtin:wiki",
          %{title: "Has Content", content: "Some text"},
          owner.id
        )

      {:ok, _no_content} =
        DataSources.create_document("builtin:wiki", %{title: "No Content"}, owner.id)

      # Drain jobs from create_document enqueuing
      Oban.drain_queue(queue: :rag_ingest)

      assert {:ok, 1} = DataSources.enqueue_index_source("builtin:wiki", owner.id)

      assert_enqueued(
        worker: Liteskill.Rag.WikiSyncWorker,
        args: %{"wiki_document_id" => with_content.id, "action" => "upsert"}
      )
    end
  end
end
