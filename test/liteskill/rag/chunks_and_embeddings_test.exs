defmodule Liteskill.Rag.ChunksAndEmbeddingsTest do
  use Liteskill.DataCase, async: true

  import Liteskill.RagTestHelpers

  alias Liteskill.Rag
  alias Liteskill.Rag.Chunk
  alias Liteskill.Rag.CohereClient
  alias Liteskill.Rag.Document

  setup :setup_users

  describe "Chunk.changeset/2" do
    test "validates required fields" do
      changeset = Chunk.changeset(%Chunk{}, %{})
      refute changeset.valid?
      assert errors_on(changeset)[:content]
      assert errors_on(changeset)[:position]
      assert errors_on(changeset)[:document_id]
    end

    test "accepts valid attrs" do
      changeset =
        Chunk.changeset(%Chunk{}, %{
          content: "test",
          position: 0,
          document_id: Ecto.UUID.generate()
        })

      assert changeset.valid?
    end
  end

  describe "embed_chunks/4" do
    test "embeds chunks and updates document status", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)

      emb1 = List.duplicate(0.1, 1024)
      emb2 = List.duplicate(0.2, 1024)
      stub_embed([emb1, emb2])

      chunks = [
        %{content: "chunk one", position: 0, metadata: %{"page" => 1}, token_count: 10},
        %{content: "chunk two", position: 1, metadata: %{"page" => 2}, token_count: 12}
      ]

      assert {:ok, updated_doc} =
               Rag.embed_chunks(doc.id, chunks, owner.id, plug: {Req.Test, CohereClient})

      assert updated_doc.status == "embedded"
      assert updated_doc.chunk_count == 2

      # Verify chunks were inserted
      db_chunks =
        Chunk
        |> where([c], c.document_id == ^doc.id)
        |> order_by([c], asc: c.position)
        |> Repo.all()

      assert length(db_chunks) == 2
      assert Enum.at(db_chunks, 0).content == "chunk one"
      assert Enum.at(db_chunks, 0).position == 0
      assert Enum.at(db_chunks, 0).token_count == 10
      assert Enum.at(db_chunks, 0).embedding
      assert Enum.at(db_chunks, 1).content == "chunk two"
    end

    test "sets document status to error on embed failure", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)

      Req.Test.stub(CohereClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"message" => "server error"}))
      end)

      chunks = [%{content: "chunk", position: 0}]

      assert {:error, %{status: 500}} =
               Rag.embed_chunks(doc.id, chunks, owner.id, plug: {Req.Test, CohereClient})

      # Document status should be "error"
      {:ok, reloaded} = Rag.get_document(doc.id, owner.id)
      assert reloaded.status == "error"
    end

    test "fails if document belongs to other user", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)

      assert {:error, :not_found} =
               Rag.embed_chunks(doc.id, [], other.id, plug: {Req.Test, CohereClient})
    end
  end

  describe "delete_document_chunks/1" do
    test "deletes all chunks for a document", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id)

      emb = List.duplicate(0.1, 1024)
      stub_embed([emb, emb])

      chunks = [
        %{content: "chunk one", position: 0},
        %{content: "chunk two", position: 1}
      ]

      {:ok, _} = Rag.embed_chunks(doc.id, chunks, owner.id, plug: {Req.Test, CohereClient})

      db_chunks = Repo.all(from(c in Chunk, where: c.document_id == ^doc.id))
      assert length(db_chunks) == 2

      assert {:ok, 2} = Rag.delete_document_chunks(doc.id)

      db_chunks = Repo.all(from(c in Chunk, where: c.document_id == ^doc.id))
      assert db_chunks == []
    end

    test "returns 0 when no chunks exist" do
      assert {:ok, 0} = Rag.delete_document_chunks(Ecto.UUID.generate())
    end
  end

  describe "list_chunks_for_document/2" do
    test "returns chunks ordered by position for owner", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id, %{title: "Chunked"})

      for pos <- [2, 0, 1] do
        %Chunk{}
        |> Chunk.changeset(%{
          content: "Chunk #{pos}",
          position: pos,
          document_id: doc.id,
          token_count: 10 + pos,
          content_hash: "hash_#{pos}"
        })
        |> Liteskill.Repo.insert!()
      end

      chunks = Rag.list_chunks_for_document(doc.id, owner.id)
      assert length(chunks) == 3
      assert Enum.map(chunks, & &1.position) == [0, 1, 2]
      assert Enum.map(chunks, & &1.content_hash) == ["hash_0", "hash_1", "hash_2"]
    end

    test "returns empty list when no chunks", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id, %{title: "Empty"})

      assert Rag.list_chunks_for_document(doc.id, owner.id) == []
    end

    test "returns empty list for unauthorized user", %{owner: owner, other: other} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id, %{title: "Secret"})

      %Chunk{}
      |> Chunk.changeset(%{
        content: "Secret chunk",
        position: 0,
        document_id: doc.id,
        token_count: 10,
        content_hash: "hash_secret"
      })
      |> Liteskill.Repo.insert!()

      assert Rag.list_chunks_for_document(doc.id, other.id) == []
    end
  end

  describe "total_chunk_count/0" do
    test "returns 0 when no chunks", %{owner: _owner} do
      assert Rag.total_chunk_count() == 0
    end

    test "returns correct count across documents", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc1} = create_document(source.id, owner.id, %{title: "Doc1"})
      {:ok, doc2} = create_document(source.id, owner.id, %{title: "Doc2"})

      for pos <- 0..2 do
        insert_chunk(doc1.id, pos)
      end

      insert_chunk(doc2.id, 0)

      assert Rag.total_chunk_count() == 4
    end
  end

  describe "clear_all_embeddings/0" do
    test "clears embeddings and resets document statuses", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id, %{title: "Embedded"})

      embedding = Pgvector.new(List.duplicate(0.1, 1024))

      chunk =
        insert_chunk(doc.id, 0, embedding: embedding)

      doc
      |> Document.changeset(%{status: "embedded", chunk_count: 1})
      |> Repo.update!()

      assert {:ok, %{chunks_cleared: 1, documents_reset: 1}} = Rag.clear_all_embeddings()

      updated_chunk = Repo.get!(Chunk, chunk.id)
      assert updated_chunk.embedding == nil

      updated_doc = Repo.get!(Document, doc.id)
      assert updated_doc.status == "pending"
    end

    test "returns zeros when nothing to clear", %{owner: _owner} do
      assert {:ok, %{chunks_cleared: 0, documents_reset: 0}} = Rag.clear_all_embeddings()
    end

    test "only clears chunks that have embeddings", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)
      {:ok, doc} = create_document(source.id, owner.id, %{title: "Mixed"})

      embedding = Pgvector.new(List.duplicate(0.1, 1024))
      insert_chunk(doc.id, 0, embedding: embedding)
      insert_chunk(doc.id, 1)

      assert {:ok, %{chunks_cleared: 1}} = Rag.clear_all_embeddings()
    end

    test "only resets documents with embedded status", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)

      {:ok, doc1} = create_document(source.id, owner.id, %{title: "Embedded"})

      doc1
      |> Document.changeset(%{status: "embedded"})
      |> Repo.update!()

      {:ok, _doc2} = create_document(source.id, owner.id, %{title: "Pending"})

      {:ok, doc3} = create_document(source.id, owner.id, %{title: "Error"})

      doc3
      |> Document.changeset(%{status: "error"})
      |> Repo.update!()

      assert {:ok, %{documents_reset: 1}} = Rag.clear_all_embeddings()
    end
  end

  describe "list_documents_for_reembedding/2" do
    test "returns pending documents with chunks", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)

      {:ok, doc1} = create_document(source.id, owner.id, %{title: "Pending With Chunks"})

      doc1
      |> Document.changeset(%{chunk_count: 3})
      |> Repo.update!()

      insert_chunk(doc1.id, 0)

      # Pending but no chunks — should NOT appear
      {:ok, _doc2} = create_document(source.id, owner.id, %{title: "Pending No Chunks"})

      # Embedded — should NOT appear
      {:ok, doc3} = create_document(source.id, owner.id, %{title: "Already Embedded"})

      doc3
      |> Document.changeset(%{status: "embedded", chunk_count: 1})
      |> Repo.update!()

      results = Rag.list_documents_for_reembedding(10, 0)
      assert length(results) == 1
      assert hd(results).id == doc1.id
    end

    test "respects limit and offset", %{owner: owner} do
      {:ok, coll} = create_collection(owner.id)
      {:ok, source} = create_source(coll.id, owner.id)

      for i <- 1..5 do
        {:ok, doc} = create_document(source.id, owner.id, %{title: "Doc #{i}"})

        doc
        |> Document.changeset(%{chunk_count: 1})
        |> Repo.update!()

        insert_chunk(doc.id, 0)
      end

      all = Rag.list_documents_for_reembedding(100, 0)
      total = length(all)

      first_batch = Rag.list_documents_for_reembedding(2, 0)
      assert length(first_batch) == 2

      second_batch = Rag.list_documents_for_reembedding(2, 2)
      assert length(second_batch) == 2

      # first and second batch should not overlap
      first_ids = MapSet.new(first_batch, & &1.id)
      second_ids = MapSet.new(second_batch, & &1.id)
      assert MapSet.disjoint?(first_ids, second_ids)

      remaining = Rag.list_documents_for_reembedding(100, 4)
      assert length(remaining) == total - 4
    end

    test "returns empty list when no pending documents", %{owner: _owner} do
      assert Rag.list_documents_for_reembedding(10, 0) == []
    end
  end

  defp insert_chunk(document_id, position, opts \\ []) do
    attrs = %{
      content: "Chunk #{position}",
      position: position,
      document_id: document_id,
      token_count: 10,
      content_hash: "hash_#{position}_#{System.unique_integer([:positive])}"
    }

    attrs =
      case Keyword.get(opts, :embedding) do
        nil -> attrs
        emb -> Map.put(attrs, :embedding, emb)
      end

    %Chunk{}
    |> Chunk.changeset(attrs)
    |> Repo.insert!()
  end
end
