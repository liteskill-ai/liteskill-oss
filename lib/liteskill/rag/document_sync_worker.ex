defmodule Liteskill.Rag.DocumentSyncWorker do
  @moduledoc """
  Oban worker that syncs a single DataSources.Document to the RAG store.

  Generalizes WikiSyncWorker: any document from any source type can be
  synced to RAG using this worker.

  Pipeline: load document -> find/create RAG collection+source ->
  delete old RAG doc if exists -> create RAG doc -> chunk -> embed.
  """

  use Oban.Worker, queue: :rag_ingest, max_attempts: 3

  alias Liteskill.DataSources
  alias Liteskill.Rag
  alias Liteskill.Rag.Chunker

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    document_id = Map.fetch!(args, "document_id")
    source_name = Map.fetch!(args, "source_name")
    user_id = Map.fetch!(args, "user_id")
    action = Map.fetch!(args, "action")
    plug = Map.get(args, "plug", false)

    case action do
      "upsert" -> do_upsert(document_id, source_name, user_id, plug)
      "delete" -> do_delete(document_id, user_id)
    end
  end

  defp do_upsert(document_id, source_name, user_id, plug) do
    case DataSources.get_document(document_id, user_id) do
      {:ok, doc} ->
        if is_nil(doc.content) || doc.content == "" do
          :ok
        else
          upsert_rag_document(doc, source_name, user_id, plug)
        end

      {:error, :not_found} ->
        :ok
    end
  end

  defp upsert_rag_document(doc, source_name, user_id, plug) do
    with {:ok, collection} <- Rag.find_or_create_collection_for_source(source_name, user_id),
         {:ok, rag_source} <-
           Rag.find_or_create_rag_source_for_source(collection.id, source_name, user_id) do
      # Remove existing RAG document if present
      case Rag.find_rag_document_by_source_doc_id(doc.id, user_id) do
        {:ok, existing} ->
          Rag.delete_document_chunks(existing.id)
          Rag.delete_document(existing.id, user_id)

        {:error, :not_found} ->
          :ok
      end

      # Create new RAG document
      {:ok, rag_doc} =
        Rag.create_document(
          rag_source.id,
          %{
            title: doc.title,
            content: doc.content,
            metadata: %{"source_document_id" => doc.id}
          },
          user_id
        )

      # Chunk and embed
      chunks = Chunker.split(doc.content)

      embed_opts =
        if plug do
          [plug: {Req.Test, Liteskill.Rag.EmbeddingClient}]
        else
          []
        end

      case Rag.embed_chunks(rag_doc.id, chunks, user_id, embed_opts) do
        {:ok, _} -> :ok
        # coveralls-ignore-next-line
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp do_delete(document_id, user_id) do
    case Rag.find_rag_document_by_source_doc_id(document_id, user_id) do
      {:ok, rag_doc} ->
        Rag.delete_document_chunks(rag_doc.id)
        Rag.delete_document(rag_doc.id, user_id)
        :ok

      {:error, :not_found} ->
        :ok
    end
  end
end
