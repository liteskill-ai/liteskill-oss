defmodule Liteskill.DataSources.SyncWorkerTest do
  use Liteskill.DataCase, async: false
  use Oban.Testing, repo: Liteskill.Repo

  alias Liteskill.DataSources
  alias Liteskill.DataSources.SyncWorker
  alias Liteskill.Rag.DocumentSyncWorker

  setup do
    {:ok, owner} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "sync-#{System.unique_integer([:positive])}@example.com",
        name: "Owner",
        oidc_sub: "sync-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{owner: owner}
  end

  describe "perform/1" do
    test "syncs a source via connector, creates documents, enqueues RAG jobs", %{owner: owner} do
      {:ok, source} =
        DataSources.create_source(%{name: "Sync Source", source_type: "wiki"}, owner.id)

      # Create a doc under this source so the wiki connector finds it
      {:ok, _doc} =
        DataSources.create_document(
          source.id,
          %{title: "Sync Page", content: "Content for sync."},
          owner.id
        )

      args = %{
        "source_id" => source.id,
        "user_id" => owner.id,
        "plug" => true
      }

      assert :ok = perform_job(SyncWorker, args)

      # Source status updated to complete
      {:ok, updated_source} = DataSources.get_source(source.id, owner.id)
      assert updated_source.sync_status == "complete"
      assert updated_source.last_synced_at

      # A DocumentSyncWorker job should be enqueued
      assert [_job] =
               all_enqueued(worker: DocumentSyncWorker)
               |> Enum.filter(fn j ->
                 j.args["source_name"] == "Sync Source" and j.args["action"] == "upsert"
               end)
    end

    test "handles source with no documents", %{owner: owner} do
      {:ok, source} =
        DataSources.create_source(%{name: "Empty Source", source_type: "wiki"}, owner.id)

      args = %{
        "source_id" => source.id,
        "user_id" => owner.id,
        "plug" => true
      }

      assert :ok = perform_job(SyncWorker, args)

      {:ok, updated_source} = DataSources.get_source(source.id, owner.id)
      assert updated_source.sync_status == "complete"
      assert updated_source.sync_document_count == 0
    end

    test "returns error for unknown connector type", %{owner: owner} do
      {:ok, source} =
        DataSources.create_source(
          %{name: "Unknown", source_type: "nonexistent_type"},
          owner.id
        )

      args = %{
        "source_id" => source.id,
        "user_id" => owner.id,
        "plug" => true
      }

      assert {:error, :unknown_connector} = perform_job(SyncWorker, args)
    end

    test "returns error for nonexistent source", %{owner: owner} do
      args = %{
        "source_id" => Ecto.UUID.generate(),
        "user_id" => owner.id,
        "plug" => true
      }

      assert {:error, :not_found} = perform_job(SyncWorker, args)
    end

    test "skips unchanged documents on re-sync", %{owner: owner} do
      {:ok, source} =
        DataSources.create_source(%{name: "Resync Test", source_type: "wiki"}, owner.id)

      {:ok, _doc} =
        DataSources.create_document(
          source.id,
          %{title: "Stable Doc", content: "Stable content."},
          owner.id
        )

      args = %{
        "source_id" => source.id,
        "user_id" => owner.id,
        "plug" => true
      }

      # First sync: creates document with external_id + content_hash
      assert :ok = perform_job(SyncWorker, args)

      first_jobs = all_enqueued(worker: DocumentSyncWorker)
      first_count = length(first_jobs)
      assert first_count >= 1

      # Second sync: content_hash unchanged, should skip
      assert :ok = perform_job(SyncWorker, args)

      # No additional DocumentSyncWorker jobs should be enqueued
      total_jobs = all_enqueued(worker: DocumentSyncWorker)
      assert length(total_jobs) == first_count
    end
  end

  describe "start_sync/2" do
    test "enqueues a sync worker job", %{owner: owner} do
      {:ok, source} =
        DataSources.create_source(%{name: "Queue Test", source_type: "wiki"}, owner.id)

      assert {:ok, _job} = DataSources.start_sync(source.id, owner.id)

      assert_enqueued(
        worker: SyncWorker,
        args: %{"source_id" => source.id, "user_id" => owner.id}
      )
    end
  end
end
