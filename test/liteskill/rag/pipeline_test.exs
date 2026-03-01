defmodule Liteskill.Rag.PipelineTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Rag
  alias Liteskill.Rag.CohereClient
  alias Liteskill.Rag.EmbeddingRequest
  alias Liteskill.Rag.Pipeline
  alias Liteskill.Repo

  setup do
    {:ok, owner} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "pipeline-owner-#{System.unique_integer([:positive])}@example.com",
        name: "Pipeline Owner",
        oidc_sub: "pipeline-owner-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, other} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "pipeline-other-#{System.unique_integer([:positive])}@example.com",
        name: "Pipeline Other",
        oidc_sub: "pipeline-other-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{owner: owner, other: other}
  end

  defp create_full_pipeline(user_id) do
    {:ok, collection} = Rag.create_collection(%{name: "Pipeline Test"}, user_id)
    {:ok, source} = Rag.create_source(collection.id, %{name: "Test Source"}, user_id)

    {:ok, document} =
      Rag.create_document(source.id, %{title: "Test Doc", content: "hello"}, user_id)

    # Stub embed and create chunks
    Req.Test.stub(CohereClient, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"embeddings" => %{"float" => [List.duplicate(0.1, 1024)]}})
      )
    end)

    {:ok, _} =
      Rag.embed_chunks(
        document.id,
        [%{content: "chunk one", position: 0}],
        user_id,
        plug: {Req.Test, CohereClient}
      )

    %{collection: collection, source: source, document: document}
  end

  defp insert_embedding_request(user_id, attrs \\ %{}) do
    default = %{
      request_type: "embed",
      status: "success",
      latency_ms: 100,
      input_count: 1,
      token_count: 50,
      model_id: "us.cohere.embed-v4:0",
      user_id: user_id
    }

    %EmbeddingRequest{}
    |> EmbeddingRequest.changeset(Map.merge(default, attrs))
    |> Repo.insert!()
  end

  describe "aggregate_stats/2" do
    test "returns zero counts for new user", %{owner: owner} do
      stats = Pipeline.aggregate_stats(owner.id)

      assert stats.source_count == 0
      assert stats.document_count == 0
      assert stats.chunk_count == 0
      assert stats.jobs_ok == 0
      assert stats.jobs_failed == 0
      assert stats.embed_requests == 0
      assert stats.embed_errors == 0
    end

    test "returns correct counts with data", %{owner: owner} do
      create_full_pipeline(owner.id)
      insert_embedding_request(owner.id)
      insert_embedding_request(owner.id, %{status: "error", error_message: "HTTP 429"})

      stats = Pipeline.aggregate_stats(owner.id)

      assert stats.source_count == 1
      assert stats.document_count == 1
      assert stats.chunk_count == 1
      # embed_requests includes the one from embed_chunks + 2 manual inserts
      assert stats.embed_requests >= 2
      assert stats.embed_errors >= 1
    end

    test "user scope filters by user", %{owner: owner, other: other} do
      create_full_pipeline(owner.id)
      create_full_pipeline(other.id)

      owner_stats = Pipeline.aggregate_stats(owner.id, scope: :user)
      assert owner_stats.source_count == 1
    end

    test "all scope returns all data", %{owner: owner, other: other} do
      create_full_pipeline(owner.id)
      create_full_pipeline(other.id)

      all_stats = Pipeline.aggregate_stats(owner.id, scope: :all)
      assert all_stats.source_count >= 2
    end
  end

  describe "windowed_rates/2" do
    test "returns rates for all windows", %{owner: owner} do
      rates = Pipeline.windowed_rates(owner.id)

      assert Map.has_key?(rates, :hour)
      assert Map.has_key?(rates, :day)
      assert Map.has_key?(rates, :week)

      for {_window, data} <- rates do
        assert Map.has_key?(data, :job_failure_rate)
        assert Map.has_key?(data, :job_retry_rate)
        assert Map.has_key?(data, :embed_failure_rate)
      end
    end

    test "rates are zero with no data", %{owner: owner} do
      rates = Pipeline.windowed_rates(owner.id)

      assert rates.hour.job_failure_rate == 0.0
      assert rates.hour.job_retry_rate == 0.0
      assert rates.hour.embed_failure_rate == 0.0
    end

    test "embed failure rate calculated correctly", %{owner: owner} do
      insert_embedding_request(owner.id, %{status: "success"})
      insert_embedding_request(owner.id, %{status: "error", error_message: "fail"})

      rates = Pipeline.windowed_rates(owner.id)
      assert rates.hour.embed_failure_rate == 50.0
    end

    test "all scope returns rates across users", %{owner: owner} do
      rates = Pipeline.windowed_rates(owner.id, scope: :all)
      assert Map.has_key?(rates.hour, :job_failure_rate)
    end
  end

  describe "chunks_per_source/2" do
    test "returns empty list with no data", %{owner: owner} do
      assert Pipeline.chunks_per_source(owner.id) == []
    end

    test "returns chunk counts grouped by source", %{owner: owner} do
      create_full_pipeline(owner.id)

      result = Pipeline.chunks_per_source(owner.id)
      assert length(result) == 1
      assert hd(result).source_name == "Test Source"
      assert hd(result).chunk_count == 1
    end

    test "all scope returns chunks across users", %{owner: owner, other: other} do
      create_full_pipeline(owner.id)
      create_full_pipeline(other.id)

      result = Pipeline.chunks_per_source(owner.id, scope: :all)
      assert length(result) >= 2
    end
  end

  describe "list_jobs/2" do
    test "returns empty list with no jobs", %{owner: owner} do
      result = Pipeline.list_jobs(owner.id)

      assert result.jobs == []
      assert result.total == 0
      assert result.page == 1
      assert result.total_pages == 1
    end

    test "paginates results", %{owner: owner} do
      result = Pipeline.list_jobs(owner.id, page: 1, page_size: 5)
      assert result.page == 1
      assert result.page_size == 5
    end

    test "clamps page to minimum 1", %{owner: owner} do
      result = Pipeline.list_jobs(owner.id, page: -1)
      assert result.page == 1
    end

    test "clamps page_size to maximum 100", %{owner: owner} do
      result = Pipeline.list_jobs(owner.id, page_size: 200)
      assert result.page_size == 100
    end

    test "all scope skips user filter", %{owner: owner} do
      result = Pipeline.list_jobs(owner.id, scope: :all)
      assert result.total >= 0
    end

    test "search filters by URL", %{owner: owner} do
      result = Pipeline.list_jobs(owner.id, search: "example.com")
      assert result.jobs == []
    end
  end

  describe "public_summary/0" do
    test "returns aggregate counts" do
      summary = Pipeline.public_summary()

      assert Map.has_key?(summary, :source_count)
      assert Map.has_key?(summary, :document_count)
      assert Map.has_key?(summary, :chunk_count)
    end
  end

  describe "safe_rate/2" do
    test "returns 0.0 when denominator is 0" do
      assert Pipeline.safe_rate(5, 0) == 0.0
    end

    test "calculates percentage correctly" do
      assert Pipeline.safe_rate(1, 4) == 25.0
    end

    test "rounds to 1 decimal place" do
      assert Pipeline.safe_rate(1, 3) == 33.3
    end
  end
end
