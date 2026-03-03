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
               [worker: DocumentSyncWorker]
               |> all_enqueued()
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

      assert :ok = DataSources.start_sync(source.id, owner.id)

      assert_enqueued(
        worker: SyncWorker,
        args: %{"source_id" => source.id, "user_id" => owner.id}
      )
    end
  end

  describe "normalize_content_type/1" do
    test "maps MIME types to short names" do
      assert SyncWorker.normalize_content_type("text/plain") == "text"
      assert SyncWorker.normalize_content_type("text/csv") == "text"
      assert SyncWorker.normalize_content_type("text/markdown") == "markdown"
      assert SyncWorker.normalize_content_type("text/html") == "html"
      assert SyncWorker.normalize_content_type("application/json") == "text"
    end

    test "passes through already-normalized types" do
      assert SyncWorker.normalize_content_type("markdown") == "markdown"
      assert SyncWorker.normalize_content_type("text") == "text"
      assert SyncWorker.normalize_content_type("html") == "html"
    end

    test "defaults unknown types to text" do
      assert SyncWorker.normalize_content_type("application/pdf") == "text"
      assert SyncWorker.normalize_content_type("image/png") == "text"
    end
  end

  describe "connector error paths" do
    test "records error status when list_entries fails", %{owner: owner} do
      # Create a google_drive source with invalid service_account_json
      # so that the connector's get_access_token fails, causing list_entries to error
      {:ok, source} =
        DataSources.create_source(
          %{name: "Error Drive", source_type: "google_drive"},
          owner.id
        )

      {:ok, source} =
        DataSources.update_source(
          source.id,
          %{
            metadata: %{
              "service_account_json" => "not valid json",
              "folder_id" => "test-folder"
            }
          },
          owner.id
        )

      args = %{
        "source_id" => source.id,
        "user_id" => owner.id,
        "plug" => true
      }

      assert {:error, :invalid_service_account} = perform_job(SyncWorker, args)

      {:ok, updated} = DataSources.get_source(source.id, owner.id)
      assert updated.sync_status == "error"
      assert updated.last_sync_error =~ "invalid_service_account"
    end
  end

  describe "sanitize_error/1" do
    test "slices binary reasons to 500 chars" do
      short = "something went wrong"
      assert SyncWorker.sanitize_error(short) == short

      long = String.duplicate("a", 600)
      assert SyncWorker.sanitize_error(long) == String.slice(long, 0, 500)
    end

    test "converts atom reasons to strings" do
      assert SyncWorker.sanitize_error(:timeout) == "timeout"
      assert SyncWorker.sanitize_error(:econnrefused) == "econnrefused"
    end

    test "inspects and slices other terms" do
      assert SyncWorker.sanitize_error({:error, :bad_gateway}) == "{:error, :bad_gateway}"
      assert SyncWorker.sanitize_error(%{code: 500}) == "%{code: 500}"
    end
  end
end
