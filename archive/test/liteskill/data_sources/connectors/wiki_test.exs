defmodule Liteskill.DataSources.Connectors.WikiTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.DataSources
  alias Liteskill.DataSources.Connectors.Wiki

  setup do
    {:ok, owner} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "wiki-conn-#{System.unique_integer([:positive])}@example.com",
        name: "Owner",
        oidc_sub: "wiki-conn-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{owner: owner}
  end

  describe "source_type/0" do
    test "returns 'wiki'" do
      assert "wiki" == Wiki.source_type()
    end
  end

  describe "validate_connection/2" do
    test "always returns :ok" do
      assert :ok == Wiki.validate_connection(%{}, [])
    end
  end

  describe "list_entries/3" do
    test "returns all wiki documents as entries", %{owner: owner} do
      {:ok, _doc1} =
        DataSources.create_document(
          "builtin:wiki",
          %{title: "Page One", content: "Content one"},
          owner.id
        )

      {:ok, _doc2} =
        DataSources.create_document(
          "builtin:wiki",
          %{title: "Page Two", content: "Content two"},
          owner.id
        )

      source = %{id: "builtin:wiki"}
      {:ok, result} = Wiki.list_entries(source, nil, user_id: owner.id)

      assert result.has_more == false
      assert result.next_cursor == nil
      assert length(result.entries) >= 2

      titles = Enum.map(result.entries, & &1.title)
      assert "Page One" in titles
      assert "Page Two" in titles

      entry = Enum.find(result.entries, &(&1.title == "Page One"))
      assert entry.content_type == "markdown"
      assert entry.deleted == false
      assert is_binary(entry.external_id)
      assert is_binary(entry.content_hash)
    end

    test "returns empty list when no documents", %{owner: owner} do
      # Create a fresh source with no docs
      {:ok, source} =
        DataSources.create_source(%{name: "Empty", source_type: "manual"}, owner.id)

      {:ok, result} = Wiki.list_entries(source, nil, user_id: owner.id)

      assert result.entries == []
      assert result.has_more == false
    end
  end

  describe "fetch_content/3" do
    test "returns document content", %{owner: owner} do
      {:ok, doc} =
        DataSources.create_document(
          "builtin:wiki",
          %{title: "Fetch Me", content: "Hello content"},
          owner.id
        )

      {:ok, result} = Wiki.fetch_content(%{}, doc.id, user_id: owner.id)

      assert result.content == "Hello content"
      assert result.content_type == "markdown"
      assert is_binary(result.content_hash)
      assert is_map(result.metadata)
    end

    test "returns error for nonexistent document", %{owner: owner} do
      assert {:error, :not_found} =
               Wiki.fetch_content(%{}, Ecto.UUID.generate(), user_id: owner.id)
    end
  end
end
