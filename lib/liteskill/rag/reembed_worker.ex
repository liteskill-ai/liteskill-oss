defmodule Liteskill.Rag.ReembedWorker do
  @moduledoc """
  Oban worker that re-embeds all chunks using the currently configured embedding model.

  Processes documents in batches. Each job handles one batch and enqueues the
  next batch if more documents remain.
  """

  use Oban.Worker, queue: :rag_ingest, max_attempts: 3

  alias Liteskill.Rag
  alias Liteskill.Rag.{Chunk, Document, EmbeddingClient, EmbedQueue}
  alias Liteskill.Repo
  alias Liteskill.Settings

  import Ecto.Query

  @batch_size 10

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    user_id = Map.fetch!(args, "user_id")
    batch = Map.get(args, "batch", 0)

    if Settings.embedding_enabled?() do
      documents = Rag.list_documents_for_reembedding(@batch_size, 0)

      if documents == [] do
        :ok
      else
        result =
          Enum.reduce_while(documents, :ok, fn doc, _acc ->
            case reembed_document(doc, user_id, args) do
              :ok -> {:cont, :ok}
              {:error, _} = err -> {:halt, err}
            end
          end)

        case result do
          :ok ->
            # Self-chain: enqueue next batch if more documents remain
            remaining = Rag.list_documents_for_reembedding(1, 0)

            if remaining != [] do
              %{"user_id" => user_id, "batch" => batch + 1}
              |> __MODULE__.new()
              |> Oban.insert()
            end

            :ok

          {:error, _} = err ->
            err
        end
      end
    else
      {:cancel, "embedding_disabled"}
    end
  end

  defp reembed_document(document, user_id, args) do
    chunks =
      from(c in Chunk, where: c.document_id == ^document.id, order_by: c.position)
      |> Repo.all()

    if chunks == [] do
      document
      |> Document.changeset(%{status: "embedded"})
      |> Repo.update()

      :ok
    else
      texts = Enum.map(chunks, & &1.content)
      plug = Map.get(args, "plug", false)

      embed_opts =
        [input_type: "search_document", user_id: user_id] ++
          if(plug, do: [plug: {Req.Test, EmbeddingClient}], else: [])

      case EmbedQueue.embed(texts, embed_opts) do
        {:ok, embeddings} ->
          Repo.transaction(fn ->
            Enum.zip(chunks, embeddings)
            |> Enum.each(fn {chunk, embedding} ->
              chunk
              |> Ecto.Changeset.change(%{embedding: Pgvector.new(embedding)})
              |> Repo.update!()
            end)

            document
            |> Document.changeset(%{status: "embedded"})
            |> Repo.update!()
          end)

          :ok

        {:error, %{status: status}} = error when status in [429, 503] ->
          # Transient — bubble up so Oban retries the whole job
          error

        {:error, _reason} ->
          # Non-retryable — mark this doc as error, continue with others
          document
          |> Document.changeset(%{status: "error"})
          |> Repo.update()

          :ok
      end
    end
  end
end
