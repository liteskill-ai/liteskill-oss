defmodule Liteskill.RagNewFunctionsTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Rag
  alias Liteskill.Rag.Chunk

  setup do
    owner = create_user(%{name: "NewFuncOwner"})
    %{owner: owner}
  end

  defp create_user(attrs) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "rag-new-#{unique}@example.com",
        name: attrs[:name] || "Test User",
        oidc_sub: "rag-new-#{unique}",
        oidc_issuer: "https://test.example.com"
      })

    user
  end

  defp create_collection(user_id) do
    Rag.create_collection(%{name: "Test Collection"}, user_id)
  end

  defp create_source(collection_id, user_id) do
    Rag.create_source(collection_id, %{name: "Test Source"}, user_id)
  end

  defp create_document(source_id, user_id) do
    Rag.create_document(source_id, %{title: "Test Document"}, user_id)
  end

  defp insert_chunk(document_id, position) do
    %Chunk{}
    |> Chunk.changeset(%{
      content: "Chunk #{position}",
      position: position,
      document_id: document_id,
      token_count: 10,
      content_hash: "hash_#{position}_#{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()
  end

  describe "reembed_in_progress?/0" do
    test "returns false when no reembed jobs exist" do
      refute Rag.reembed_in_progress?()
    end
  end

  describe "get_document_with_source/2" do
    test "returns document with preloaded source", %{owner: owner} do
      {:ok, collection} = create_collection(owner.id)
      {:ok, source} = create_source(collection.id, owner.id)
      {:ok, document} = create_document(source.id, owner.id)

      assert {:ok, loaded} = Rag.get_document_with_source(document.id, owner.id)
      assert loaded.id == document.id
      assert loaded.source.id == source.id
    end

    test "returns error for nonexistent document", %{owner: owner} do
      assert {:error, :not_found} = Rag.get_document_with_source(Ecto.UUID.generate(), owner.id)
    end
  end

  describe "preload_result_sources/1" do
    test "returns empty list for empty input" do
      assert Rag.preload_result_sources([]) == []
    end

    test "preloads document and source on result chunks", %{owner: owner} do
      {:ok, collection} = create_collection(owner.id)
      {:ok, source} = create_source(collection.id, owner.id)
      {:ok, document} = create_document(source.id, owner.id)
      chunk = insert_chunk(document.id, 0)

      results = [%{chunk: chunk, distance: 0.5}]
      [preloaded] = Rag.preload_result_sources(results)

      assert preloaded.chunk.document.id == document.id
      assert preloaded.chunk.document.source.id == source.id
      assert preloaded.distance == 0.5
    end
  end

  describe "augment_context_for_agent/4" do
    test "returns empty list when no collections match source IDs", %{owner: owner} do
      nonexistent_id = Ecto.UUID.generate()

      assert {:ok, []} =
               Rag.augment_context_for_agent("query", [nonexistent_id], owner.id, plug: true)
    end
  end
end
