defmodule Liteskill.Rag.SourcesAndDocumentsTest do
  use Liteskill.DataCase, async: true

  import Liteskill.RagTestHelpers

  alias Liteskill.Rag
  alias Liteskill.Rag.CohereClient
  alias Liteskill.Rag.Document
  alias Liteskill.Rag.Source

  setup :setup_users

  # --- Sources ---

  describe "create_source/3" do
    test "creates source with valid attrs", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      assert {:ok, %Source{} = source} = create_source(coll.id, owner.id)
      assert source.name == "Test Source"
      assert source.source_type == "manual"
      assert source.collection_id == coll.id
    end

    test "creates source with custom type", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)

      assert {:ok, source} =
               create_source(coll.id, owner.id, %{source_type: "upload"})

      assert source.source_type == "upload"
    end

    test "fails with invalid source_type", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)

      assert {:error, %Ecto.Changeset{}} =
               create_source(coll.id, owner.id, %{source_type: "invalid"})
    end

    test "fails if collection belongs to other user", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      assert {:error, :not_found} = create_source(coll.id, other.id)
    end
  end

  describe "list_sources/2" do
    test "lists sources in collection", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, _} = create_source(coll.id, owner.id, %{name: "A"})
      {:ok, _} = create_source(coll.id, owner.id, %{name: "B"})

      assert {:ok, sources} = Rag.list_sources(coll.id, owner.id)
      assert length(sources) == 2
      assert Enum.map(sources, & &1.name) == ["A", "B"]
    end

    test "non-owner cannot list", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      assert {:error, :not_found} = Rag.list_sources(coll.id, other.id)
    end
  end

  describe "get_source/2" do
    test "returns own source", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      assert {:ok, found} = Rag.get_source(source.id, owner.id)
      assert found.id == source.id
    end

    test "returns not_found for other user", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      assert {:error, :not_found} = Rag.get_source(source.id, other.id)
    end

    test "returns not_found for nonexistent id", %{owner: owner} do
      assert {:error, :not_found} = Rag.get_source(Ecto.UUID.generate(), owner.id)
    end
  end

  describe "update_source/3" do
    test "owner can update", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      assert {:ok, updated} = Rag.update_source(source.id, %{name: "Updated"}, owner.id)
      assert updated.name == "Updated"
    end

    test "non-owner cannot update", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      assert {:error, :not_found} = Rag.update_source(source.id, %{name: "X"}, other.id)
    end
  end

  describe "delete_source/2" do
    test "owner can delete", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      assert {:ok, _} = Rag.delete_source(source.id, owner.id)
      assert {:ok, []} = Rag.list_sources(coll.id, owner.id)
    end

    test "non-owner cannot delete", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      assert {:error, :not_found} = Rag.delete_source(source.id, other.id)
    end
  end

  # --- Documents ---

  describe "create_document/3" do
    test "creates document with valid attrs", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      assert {:ok, %Document{} = doc} = create_document(source.id, owner.id)
      assert doc.title == "Test Document"
      assert doc.status == "pending"
      assert doc.chunk_count == 0
    end

    test "creates document with content and metadata", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)

      assert {:ok, doc} =
               create_document(source.id, owner.id, %{
                 content: "full text here",
                 metadata: %{"key" => "value"}
               })

      assert doc.content == "full text here"
      assert doc.metadata == %{"key" => "value"}
    end

    test "fails if source belongs to other user", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      assert {:error, :not_found} = create_document(source.id, other.id)
    end
  end

  describe "list_documents/2" do
    test "lists documents in source", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, _} = create_document(source.id, owner.id, %{title: "A"})
      {:ok, _} = create_document(source.id, owner.id, %{title: "B"})

      assert {:ok, docs} = Rag.list_documents(source.id, owner.id)
      assert length(docs) == 2
      assert Enum.map(docs, & &1.title) == ["A", "B"]
    end

    test "non-owner cannot list", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      assert {:error, :not_found} = Rag.list_documents(source.id, other.id)
    end
  end

  describe "get_document/2" do
    test "returns own document", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)
      assert {:ok, found} = Rag.get_document(doc.id, owner.id)
      assert found.id == doc.id
    end

    test "returns not_found for other user", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)
      assert {:error, :not_found} = Rag.get_document(doc.id, other.id)
    end

    test "returns not_found for nonexistent id", %{owner: owner} do
      assert {:error, :not_found} = Rag.get_document(Ecto.UUID.generate(), owner.id)
    end
  end

  describe "delete_document/2" do
    test "owner can delete", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)
      assert {:ok, _} = Rag.delete_document(doc.id, owner.id)
      assert {:ok, []} = Rag.list_documents(source.id, owner.id)
    end

    test "non-owner cannot delete", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)
      assert {:error, :not_found} = Rag.delete_document(doc.id, other.id)
    end
  end

  # --- Wiki Helpers ---

  describe "find_or_create_wiki_collection/1" do
    test "creates wiki collection on first call", %{owner: owner} do
      assert {:ok, coll} = Rag.find_or_create_wiki_collection(owner.id)
      assert coll.name == "Wiki"
      assert coll.user_id == owner.id
    end

    test "returns existing wiki collection on second call", %{owner: owner} do
      {:ok, coll1} = Rag.find_or_create_wiki_collection(owner.id)
      {:ok, coll2} = Rag.find_or_create_wiki_collection(owner.id)
      assert coll1.id == coll2.id
    end

    test "creates separate collections per user", %{owner: owner, other: other} do
      {:ok, coll1} = Rag.find_or_create_wiki_collection(owner.id)
      {:ok, coll2} = Rag.find_or_create_wiki_collection(other.id)
      assert coll1.id != coll2.id
    end
  end

  describe "find_or_create_wiki_source/2" do
    test "creates wiki source on first call", %{owner: owner} do
      {:ok, coll} = Rag.find_or_create_wiki_collection(owner.id)
      assert {:ok, source} = Rag.find_or_create_wiki_source(coll.id, owner.id)
      assert source.name == "wiki"
      assert source.collection_id == coll.id
    end

    test "returns existing wiki source on second call", %{owner: owner} do
      {:ok, coll} = Rag.find_or_create_wiki_collection(owner.id)
      {:ok, src1} = Rag.find_or_create_wiki_source(coll.id, owner.id)
      {:ok, src2} = Rag.find_or_create_wiki_source(coll.id, owner.id)
      assert src1.id == src2.id
    end
  end

  describe "find_rag_document_by_wiki_id/2" do
    test "finds document by wiki_document_id metadata", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      wiki_id = Ecto.UUID.generate()

      {:ok, doc} =
        create_document(source.id, owner.id, %{
          metadata: %{"wiki_document_id" => wiki_id}
        })

      assert {:ok, found} = Rag.find_rag_document_by_wiki_id(wiki_id, owner.id)
      assert found.id == doc.id
    end

    test "returns not_found when no match", %{owner: owner} do
      assert {:error, :not_found} =
               Rag.find_rag_document_by_wiki_id(Ecto.UUID.generate(), owner.id)
    end

    test "scoped to user_id", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      wiki_id = Ecto.UUID.generate()

      {:ok, _doc} =
        create_document(source.id, owner.id, %{
          metadata: %{"wiki_document_id" => wiki_id}
        })

      assert {:error, :not_found} = Rag.find_rag_document_by_wiki_id(wiki_id, other.id)
    end

    test "returns doc for user with wiki space ACL", %{owner: owner, other: other} do
      {:ok, space} =
        Liteskill.DataSources.create_document("builtin:wiki", %{title: "Shared"}, owner.id)

      {:ok, _} =
        Liteskill.Authorization.grant_access("wiki_space", space.id, owner.id, other.id, "viewer")

      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      wiki_id = Ecto.UUID.generate()

      {:ok, doc} =
        create_document(source.id, owner.id, %{
          metadata: %{"wiki_document_id" => wiki_id, "wiki_space_id" => space.id}
        })

      assert {:ok, found} = Rag.find_rag_document_by_wiki_id(wiki_id, other.id)
      assert found.id == doc.id
    end

    test "fallback resolves and backfills missing wiki_space_id", %{owner: owner, other: other} do
      {:ok, space} =
        Liteskill.DataSources.create_document("builtin:wiki", %{title: "Shared"}, owner.id)

      {:ok, _} =
        Liteskill.Authorization.grant_access("wiki_space", space.id, owner.id, other.id, "viewer")

      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)

      # RAG doc with wiki_document_id pointing to a real wiki doc in the space,
      # but missing wiki_space_id (pre-backfill scenario)
      {:ok, wiki_child} =
        Liteskill.DataSources.create_child_document(
          "builtin:wiki",
          space.id,
          %{title: "Child Page"},
          owner.id
        )

      {:ok, rag_doc} =
        create_document(source.id, owner.id, %{
          metadata: %{"wiki_document_id" => wiki_child.id}
        })

      # Other user should still find it via fallback
      assert {:ok, found} = Rag.find_rag_document_by_wiki_id(wiki_child.id, other.id)
      assert found.id == rag_doc.id
      # wiki_space_id should be backfilled
      assert found.metadata["wiki_space_id"] == space.id
    end

    test "fallback returns :not_found without ACL access", %{owner: owner, other: other} do
      {:ok, space} =
        Liteskill.DataSources.create_document("builtin:wiki", %{title: "Private"}, owner.id)

      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)

      {:ok, wiki_child} =
        Liteskill.DataSources.create_child_document(
          "builtin:wiki",
          space.id,
          %{title: "Child Page"},
          owner.id
        )

      {:ok, _rag_doc} =
        create_document(source.id, owner.id, %{
          metadata: %{"wiki_document_id" => wiki_child.id}
        })

      # No ACL — should return :not_found
      assert {:error, :not_found} = Rag.find_rag_document_by_wiki_id(wiki_child.id, other.id)
    end
  end

  # --- get_rag_document_for_source_doc ---

  describe "get_rag_document_for_source_doc/2" do
    test "finds RAG document linked via wiki_document_id metadata", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      wiki_doc_id = Ecto.UUID.generate()

      {:ok, rag_doc} =
        create_document(source.id, owner.id, %{
          title: "Wiki Doc",
          metadata: %{"wiki_document_id" => wiki_doc_id}
        })

      assert {:ok, found} = Rag.get_rag_document_for_source_doc(wiki_doc_id, owner.id)
      assert found.id == rag_doc.id
    end

    test "returns :not_found when no matching RAG document", %{owner: owner} do
      assert {:error, :not_found} =
               Rag.get_rag_document_for_source_doc(Ecto.UUID.generate(), owner.id)
    end

    test "returns :not_found for another user's RAG document", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(other.id)
      {:ok, source} = create_source(coll.id, other.id)
      wiki_doc_id = Ecto.UUID.generate()

      {:ok, _} =
        create_document(source.id, other.id, %{
          title: "Other Doc",
          metadata: %{"wiki_document_id" => wiki_doc_id}
        })

      assert {:error, :not_found} = Rag.get_rag_document_for_source_doc(wiki_doc_id, owner.id)
    end

    test "returns doc for user with wiki space ACL via wiki_document_id", %{
      owner: owner,
      other: other
    } do
      {:ok, space} =
        Liteskill.DataSources.create_document("builtin:wiki", %{title: "Shared"}, owner.id)

      {:ok, _} =
        Liteskill.Authorization.grant_access("wiki_space", space.id, owner.id, other.id, "viewer")

      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      wiki_doc_id = Ecto.UUID.generate()

      {:ok, doc} =
        create_document(source.id, owner.id, %{
          title: "Shared Wiki Doc",
          metadata: %{"wiki_document_id" => wiki_doc_id, "wiki_space_id" => space.id}
        })

      assert {:ok, found} = Rag.get_rag_document_for_source_doc(wiki_doc_id, other.id)
      assert found.id == doc.id
    end

    test "returns doc for user with wiki space ACL via source_document_id", %{
      owner: owner,
      other: other
    } do
      {:ok, space} =
        Liteskill.DataSources.create_document("builtin:wiki", %{title: "Shared"}, owner.id)

      {:ok, _} =
        Liteskill.Authorization.grant_access("wiki_space", space.id, owner.id, other.id, "viewer")

      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      source_doc_id = Ecto.UUID.generate()

      {:ok, doc} =
        create_document(source.id, owner.id, %{
          title: "Shared Source Doc",
          metadata: %{"source_document_id" => source_doc_id, "wiki_space_id" => space.id}
        })

      assert {:ok, found} = Rag.get_rag_document_for_source_doc(source_doc_id, other.id)
      assert found.id == doc.id
    end

    test "fallback resolves missing wiki_space_id via wiki_document_id", %{
      owner: owner,
      other: other
    } do
      {:ok, space} =
        Liteskill.DataSources.create_document("builtin:wiki", %{title: "Shared"}, owner.id)

      {:ok, _} =
        Liteskill.Authorization.grant_access("wiki_space", space.id, owner.id, other.id, "viewer")

      {:ok, wiki_child} =
        Liteskill.DataSources.create_child_document(
          "builtin:wiki",
          space.id,
          %{title: "Child Page"},
          owner.id
        )

      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)

      {:ok, rag_doc} =
        create_document(source.id, owner.id, %{
          title: "Missing Space ID",
          metadata: %{"wiki_document_id" => wiki_child.id}
        })

      assert {:ok, found} = Rag.get_rag_document_for_source_doc(wiki_child.id, other.id)
      assert found.id == rag_doc.id
      assert found.metadata["wiki_space_id"] == space.id
    end
  end

  describe "find_rag_document_by_source_doc_id/2" do
    test "returns doc for user with wiki space ACL", %{owner: owner, other: other} do
      {:ok, space} =
        Liteskill.DataSources.create_document("builtin:wiki", %{title: "Shared"}, owner.id)

      {:ok, _} =
        Liteskill.Authorization.grant_access("wiki_space", space.id, owner.id, other.id, "viewer")

      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      source_doc_id = Ecto.UUID.generate()

      {:ok, doc} =
        create_document(source.id, owner.id, %{
          title: "Shared Doc",
          metadata: %{"source_document_id" => source_doc_id, "wiki_space_id" => space.id}
        })

      assert {:ok, found} = Rag.find_rag_document_by_source_doc_id(source_doc_id, other.id)
      assert found.id == doc.id
    end

    test "returns :not_found without wiki space ACL", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      source_doc_id = Ecto.UUID.generate()

      {:ok, _} =
        create_document(source.id, owner.id, %{
          title: "Private Doc",
          metadata: %{"source_document_id" => source_doc_id}
        })

      assert {:error, :not_found} =
               Rag.find_rag_document_by_source_doc_id(source_doc_id, other.id)
    end
  end

  # --- SHA256 Content Hashing ---

  describe "SHA256 content hashing" do
    test "create_document sets content_hash when content is provided", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)

      {:ok, doc} =
        create_document(source.id, owner.id, %{content: "hello world"})

      expected_hash =
        :sha256 |> :crypto.hash("hello world") |> Base.encode16(case: :lower)

      assert doc.content_hash == expected_hash
    end

    test "create_document leaves content_hash nil when no content", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)

      {:ok, doc} = create_document(source.id, owner.id)
      assert doc.content_hash == nil
    end

    test "embed_chunks sets content_hash on chunks", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)

      stub_embed([List.duplicate(0.1, 1024)])
      chunks = [%{content: "chunk content", position: 0}]

      assert {:ok, _} =
               Rag.embed_chunks(doc.id, chunks, owner.id, plug: {Req.Test, CohereClient})

      db_chunks = Liteskill.Rag.Chunk |> where([c], c.document_id == ^doc.id) |> Repo.all()
      assert length(db_chunks) == 1

      expected_hash =
        :sha256 |> :crypto.hash("chunk content") |> Base.encode16(case: :lower)

      assert hd(db_chunks).content_hash == expected_hash
    end
  end
end
