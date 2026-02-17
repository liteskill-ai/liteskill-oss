defmodule Liteskill.DataSources.SyncWorker do
  @moduledoc """
  Oban worker that orchestrates a full sync for a data source.

  Pipeline:
  1. Load source, resolve connector via ConnectorRegistry
  2. Mark source sync_status = "syncing"
  3. Paginate through connector.list_entries (using stored cursor)
  4. For new/changed entries: fetch content via connector, upsert document
  5. For changed/new documents: enqueue DocumentSyncWorker jobs
  6. Update source sync_cursor, sync_status, last_synced_at
  """

  use Oban.Worker,
    queue: :data_sync,
    max_attempts: 3,
    unique: [period: 300, fields: [:args], keys: [:source_id]]

  alias Liteskill.DataSources
  alias Liteskill.DataSources.ConnectorRegistry

  require Logger

  # 10 MB max document content size
  @max_content_bytes 10_485_760

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    source_id = Map.fetch!(args, "source_id")
    user_id = Map.fetch!(args, "user_id")
    plug = Map.get(args, "plug", false)

    with {:ok, source} <- DataSources.get_source(source_id, user_id),
         {:ok, connector} <- ConnectorRegistry.get(source.source_type) do
      DataSources.update_sync_status(source, "syncing")

      cursor = if source.sync_cursor == %{}, do: nil, else: source.sync_cursor
      opts = [user_id: user_id, plug: plug]

      case sync_loop(source, connector, cursor, opts, 0) do
        {:ok, new_cursor, doc_count} ->
          DataSources.update_sync_cursor(source, new_cursor, doc_count)
          DataSources.update_sync_status(source, "complete")
          :ok

        # coveralls-ignore-start
        {:error, reason} ->
          DataSources.update_sync_status(source, "error", sanitize_error(reason))
          {:error, reason}
          # coveralls-ignore-stop
      end
    end
  end

  defp sync_loop(source, connector, cursor, opts, doc_count) do
    case connector.list_entries(source, cursor, opts) do
      {:ok, %{entries: entries, next_cursor: next_cursor, has_more: has_more}} ->
        new_count = doc_count + process_entries(source, connector, entries, opts)

        if has_more do
          # coveralls-ignore-next-line
          sync_loop(source, connector, next_cursor, opts, new_count)
        else
          {:ok, next_cursor, new_count}
        end

      # coveralls-ignore-start
      {:error, reason} ->
        {:error, reason}
        # coveralls-ignore-stop
    end
  end

  defp process_entries(source, connector, entries, opts) do
    user_id = Keyword.fetch!(opts, :user_id)
    plug = Keyword.get(opts, :plug, false)

    Enum.reduce(entries, 0, fn entry, count ->
      if entry.deleted do
        # coveralls-ignore-start
        handle_delete(source, entry, user_id, plug)
        count
        # coveralls-ignore-stop
      else
        case handle_upsert(source, connector, entry, user_id, plug, opts) do
          :changed -> count + 1
          :unchanged -> count
          # coveralls-ignore-next-line
          :error -> count
        end
      end
    end)
  end

  # coveralls-ignore-start
  defp handle_delete(source, entry, user_id, plug) do
    case DataSources.delete_document_by_external_id(source.id, entry.external_id, user_id) do
      {:ok, %{id: doc_id}} ->
        enqueue_document_sync(doc_id, source.name, user_id, "delete", plug)

      _ ->
        :ok
    end
  end

  # coveralls-ignore-stop

  defp handle_upsert(source, connector, entry, user_id, plug, opts) do
    # Check if content_hash changed compared to existing document
    existing = DataSources.get_document_by_external_id(source.id, entry.external_id)

    if existing && existing.content_hash == entry.content_hash && entry.content_hash != nil do
      :unchanged
    else
      # Fetch full content from connector
      case connector.fetch_content(source, entry.external_id, opts) do
        {:ok, fetched} ->
          upsert_fetched_content(source, entry, fetched, user_id, plug)

        # coveralls-ignore-start
        {:error, _reason} ->
          :error
          # coveralls-ignore-stop
      end
    end
  end

  defp upsert_fetched_content(source, entry, fetched, user_id, plug) do
    content_size = byte_size(fetched.content || "")

    # coveralls-ignore-start
    if content_size > @max_content_bytes do
      Logger.warning(
        "SyncWorker: skipping oversized document #{entry.external_id} " <>
          "(#{content_size} bytes > #{@max_content_bytes} limit)"
      )

      :unchanged
    else
      # coveralls-ignore-stop
      attrs = %{
        title: entry.title,
        content_type: normalize_content_type(fetched.content_type),
        metadata: entry.metadata,
        content: fetched.content,
        content_hash: fetched.content_hash
      }

      case DataSources.upsert_document_by_external_id(
             source.id,
             entry.external_id,
             attrs,
             user_id
           ) do
        {:ok, status, doc} when status in [:created, :updated] ->
          if doc.content && doc.content != "" do
            enqueue_document_sync(doc.id, source.name, user_id, "upsert", plug)
          end

          :changed

        # coveralls-ignore-start
        {:ok, :unchanged, _doc} ->
          :unchanged

        {:error, _reason} ->
          :error
          # coveralls-ignore-stop
      end
    end
  end

  # coveralls-ignore-start
  defp normalize_content_type("text/plain"), do: "text"
  defp normalize_content_type("text/csv"), do: "text"
  defp normalize_content_type("text/markdown"), do: "markdown"
  defp normalize_content_type("text/html"), do: "html"
  defp normalize_content_type("application/json"), do: "text"
  defp normalize_content_type(type) when type in ["markdown", "text", "html"], do: type
  defp normalize_content_type(_), do: "text"
  # coveralls-ignore-stop

  # coveralls-ignore-start
  # sanitize_error clauses are defensive — connector errors always come as maps/tuples
  defp sanitize_error(reason) when is_binary(reason), do: String.slice(reason, 0, 500)
  defp sanitize_error(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp sanitize_error(reason) do
    reason |> inspect() |> String.slice(0, 500)
  end

  # coveralls-ignore-stop

  defp enqueue_document_sync(document_id, source_name, user_id, action, plug) do
    %{
      "document_id" => document_id,
      "source_name" => source_name,
      "user_id" => user_id,
      "action" => action,
      "plug" => plug
    }
    |> Oban.Job.new(
      worker: "Liteskill.Rag.DocumentSyncWorker",
      queue: :rag_ingest,
      max_attempts: 3
    )
    |> Oban.insert()
  end
end
