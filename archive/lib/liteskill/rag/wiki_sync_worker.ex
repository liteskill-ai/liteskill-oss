defmodule Liteskill.Rag.WikiSyncWorker do
  @moduledoc """
  Oban worker that syncs wiki page changes to the RAG store.

  On upsert: chunks the wiki page content, embeds it, and stores it.
  On delete: removes the RAG document and its chunks.
  """

  use Oban.Worker, queue: :rag_ingest, max_attempts: 3

  alias Liteskill.DataSources
  alias Liteskill.Rag
  alias Liteskill.Rag.Chunker

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    wiki_document_id = Map.fetch!(args, "wiki_document_id")
    user_id = Map.fetch!(args, "user_id")
    action = Map.fetch!(args, "action")
    plug = Map.get(args, "plug", false)

    case action do
      "upsert" -> do_upsert(wiki_document_id, user_id, plug)
      "delete" -> do_delete(wiki_document_id, user_id)
    end
  end

  defp do_upsert(wiki_document_id, user_id, plug) do
    case DataSources.get_document(wiki_document_id, user_id) do
      {:ok, wiki_doc} ->
        if is_nil(wiki_doc.content) || wiki_doc.content == "" do
          :ok
        else
          upsert_rag_document(wiki_doc, user_id, plug)
        end

      {:error, :not_found} ->
        :ok
    end
  end

  defp upsert_rag_document(wiki_doc, user_id, plug) do
    with {:ok, collection} <- Rag.find_or_create_wiki_collection(user_id),
         {:ok, source} <- Rag.find_or_create_wiki_source(collection.id, user_id) do
      # Remove existing RAG document if present
      case Rag.find_rag_document_by_wiki_id(wiki_doc.id, user_id) do
        {:ok, existing} ->
          Rag.delete_document_chunks(existing.id)
          Rag.delete_document(existing.id, user_id)

        {:error, :not_found} ->
          :ok
      end

      # Create new RAG document
      {:ok, rag_doc} =
        Rag.create_document(
          source.id,
          %{
            title: wiki_doc.title,
            content: wiki_doc.content,
            metadata: %{
              "wiki_document_id" => wiki_doc.id,
              "wiki_space_id" => DataSources.get_space_id(wiki_doc)
            }
          },
          user_id
        )

      # Chunk and embed
      chunks = Chunker.split(wiki_doc.content)

      embed_opts =
        if plug do
          [plug: {Req.Test, Liteskill.Rag.EmbeddingClient}]
        else
          []
        end

      case Rag.embed_chunks(rag_doc.id, chunks, user_id, embed_opts) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp do_delete(wiki_document_id, user_id) do
    case Rag.find_rag_document_by_wiki_id(wiki_document_id, user_id) do
      {:ok, rag_doc} ->
        Rag.delete_document_chunks(rag_doc.id)
        Rag.delete_document(rag_doc.id, user_id)
        :ok

      {:error, :not_found} ->
        :ok
    end
  end
end
