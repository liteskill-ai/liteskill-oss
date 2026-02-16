defmodule Liteskill.Rag.ReembedWorkerTest do
  use Liteskill.DataCase, async: false
  use Oban.Testing, repo: Liteskill.Repo

  alias Liteskill.Rag
  alias Liteskill.Rag.{Chunk, CohereClient, Document, ReembedWorker}
  alias Liteskill.Settings

  setup do
    {:ok, owner} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "reembed-owner-#{System.unique_integer([:positive])}@example.com",
        name: "Owner",
        oidc_sub: "reembed-owner-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, collection} = Rag.create_collection(%{name: "Reembed Test"}, owner.id)
    {:ok, source} = Rag.create_source(collection.id, %{name: "Test Source"}, owner.id)

    # Set up embedding model in settings
    model = create_embedding_model(owner)
    Settings.get()
    {:ok, _} = Settings.update_embedding_model(model.id)

    %{owner: owner, collection: collection, source: source, model: model}
  end

  defp stub_embed(embeddings) do
    Req.Test.stub(CohereClient, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"embeddings" => %{"float" => embeddings}})
      )
    end)
  end

  defp stub_embed_error do
    Req.Test.stub(CohereClient, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(500, Jason.encode!(%{"message" => "Internal error"}))
    end)
  end

  defp create_pending_doc(source_id, owner_id, chunk_count) do
    {:ok, doc} =
      Rag.create_document(
        source_id,
        %{title: "Doc #{System.unique_integer([:positive])}"},
        owner_id
      )

    doc =
      doc
      |> Document.changeset(%{chunk_count: chunk_count})
      |> Repo.update!()

    chunks =
      for pos <- 0..(chunk_count - 1) do
        %Chunk{}
        |> Chunk.changeset(%{
          content: "Chunk #{pos} content",
          position: pos,
          document_id: doc.id,
          token_count: 10,
          content_hash: "hash_#{pos}_#{System.unique_integer([:positive])}"
        })
        |> Repo.insert!()
      end

    {doc, chunks}
  end

  describe "perform/1" do
    test "re-embeds pending documents", %{owner: owner, source: source} do
      {doc, _chunks} = create_pending_doc(source.id, owner.id, 2)

      embedding = List.duplicate(0.1, 1024)
      stub_embed([embedding, embedding])

      assert :ok =
               perform_job(ReembedWorker, %{
                 "user_id" => owner.id,
                 "plug" => true
               })

      updated_doc = Repo.get!(Document, doc.id)
      assert updated_doc.status == "embedded"

      chunks = Rag.list_chunks_for_document(doc.id)

      Enum.each(chunks, fn chunk ->
        assert chunk.embedding != nil
      end)
    end

    test "cancels when embedding is disabled", %{owner: owner} do
      {:ok, _} = Settings.update_embedding_model(nil)

      assert {:cancel, "embedding_disabled"} =
               perform_job(ReembedWorker, %{
                 "user_id" => owner.id,
                 "plug" => true
               })
    end

    test "returns :ok when no pending documents", %{owner: owner} do
      stub_embed([])

      assert :ok =
               perform_job(ReembedWorker, %{
                 "user_id" => owner.id,
                 "plug" => true
               })
    end

    test "marks document as error on embed failure", %{owner: owner, source: source} do
      {doc, _chunks} = create_pending_doc(source.id, owner.id, 1)

      stub_embed_error()

      assert :ok =
               perform_job(ReembedWorker, %{
                 "user_id" => owner.id,
                 "plug" => true
               })

      updated_doc = Repo.get!(Document, doc.id)
      assert updated_doc.status == "error"
    end

    test "returns error on 429 without marking document as error", %{
      owner: owner,
      source: source
    } do
      {doc, _chunks} = create_pending_doc(source.id, owner.id, 1)

      Req.Test.stub(CohereClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(429, Jason.encode!(%{"message" => "Rate limited"}))
      end)

      assert {:error, _} =
               perform_job(ReembedWorker, %{
                 "user_id" => owner.id,
                 "plug" => true
               })

      updated_doc = Repo.get!(Document, doc.id)
      assert updated_doc.status == "pending"
    end

    test "handles document with zero chunks gracefully", %{owner: owner, source: source} do
      {:ok, doc} =
        Rag.create_document(source.id, %{title: "No Chunks"}, owner.id)

      doc
      |> Document.changeset(%{chunk_count: 1})
      |> Repo.update!()

      # chunk_count > 0 so it shows up in list_documents_for_reembedding,
      # but no actual chunks in DB — worker should mark it embedded

      assert :ok =
               perform_job(ReembedWorker, %{
                 "user_id" => owner.id,
                 "plug" => true
               })

      updated_doc = Repo.get!(Document, doc.id)
      assert updated_doc.status == "embedded"
    end

    test "self-chains when more documents remain with incremented batch", %{
      owner: owner,
      source: source
    } do
      # Create more docs than @batch_size (10)
      for _ <- 1..12 do
        create_pending_doc(source.id, owner.id, 1)
      end

      embedding = List.duplicate(0.1, 1024)
      stub_embed([embedding])

      assert :ok =
               perform_job(ReembedWorker, %{
                 "user_id" => owner.id,
                 "batch" => 0,
                 "plug" => true
               })

      # Should have enqueued a follow-up job with incremented batch
      assert_enqueued(worker: ReembedWorker, args: %{"batch" => 1})
    end
  end

  defp create_embedding_model(owner) do
    {:ok, provider} =
      Liteskill.LlmProviders.create_provider(%{
        name: "Reembed Test Bedrock",
        provider_type: "amazon_bedrock",
        api_key: "test-key",
        provider_config: %{"region" => "us-east-1"},
        user_id: owner.id
      })

    {:ok, model} =
      Liteskill.LlmModels.create_model(%{
        name: "Cohere Embed v4",
        model_id: "us.cohere.embed-v4:0",
        model_type: "embedding",
        instance_wide: true,
        provider_id: provider.id,
        user_id: owner.id
      })

    model
  end
end
