defmodule Liteskill.Rag.Pipeline do
  @moduledoc """
  Dashboard query logic for the RAG ingest pipeline.
  Provides aggregate stats, windowed rates, chart data, and job listing.
  """

  alias Liteskill.Rag.{Collection, Source, Document, Chunk, EmbeddingRequest}
  alias Liteskill.Repo

  import Ecto.Query

  @doc """
  Returns aggregate counts for the pipeline dashboard.

  Options:
    - `scope` - `:user` (default) or `:all`
  """
  def aggregate_stats(user_id, opts \\ []) do
    scope = Keyword.get(opts, :scope, :user)

    %{
      source_count: count_sources(user_id, scope),
      document_count: count_documents(user_id, scope),
      chunk_count: count_chunks(user_id, scope),
      jobs_ok: count_jobs(user_id, scope, "completed"),
      jobs_failed: count_jobs(user_id, scope, "discarded"),
      embed_requests: count_embed_requests(user_id, scope, nil),
      embed_errors: count_embed_requests(user_id, scope, "error")
    }
  end

  @doc """
  Returns failure and retry rates for 1h, 24h, and 7d windows.
  """
  def windowed_rates(user_id, opts \\ []) do
    scope = Keyword.get(opts, :scope, :user)

    for window <- [:hour, :day, :week], into: %{} do
      cutoff = window_cutoff(window)
      {total, failed, retried} = job_counts_since(user_id, scope, cutoff)
      {embed_total, embed_failed} = embed_counts_since(user_id, scope, cutoff)

      {window,
       %{
         job_failure_rate: safe_rate(failed, total),
         job_retry_rate: safe_rate(retried, total),
         embed_failure_rate: safe_rate(embed_failed, embed_total)
       }}
    end
  end

  @doc """
  Returns chunk counts per data source for pie chart.
  """
  def chunks_per_source(user_id, opts \\ []) do
    scope = Keyword.get(opts, :scope, :user)

    base =
      from(c in Chunk,
        join: d in Document,
        on: d.id == c.document_id,
        join: s in Source,
        on: s.id == d.source_id,
        join: coll in Collection,
        on: coll.id == s.collection_id,
        group_by: [s.id, s.name],
        select: %{source_name: s.name, chunk_count: count(c.id)}
      )

    base
    |> maybe_scope_collection(user_id, scope)
    |> order_by([c, d, s, coll], desc: count(c.id))
    |> Repo.all()
  end

  @doc """
  Returns paginated, searchable Oban job list for the rag_ingest queue.

  Options:
    - `scope` - `:user` (default) or `:all`
    - `page` - page number (default 1)
    - `page_size` - items per page (default 20)
    - `search` - URL search term
  """
  def list_jobs(user_id, opts \\ []) do
    scope = Keyword.get(opts, :scope, :user)
    page = max(Keyword.get(opts, :page, 1), 1)
    page_size = min(Keyword.get(opts, :page_size, 20), 100)
    search = Keyword.get(opts, :search)

    base =
      from(j in "oban_jobs",
        where: j.queue == "rag_ingest",
        order_by: [desc: j.inserted_at],
        select: %{
          id: j.id,
          state: j.state,
          args: j.args,
          attempt: j.attempt,
          max_attempts: j.max_attempts,
          inserted_at: j.inserted_at,
          completed_at: j.completed_at
        }
      )

    base =
      if scope == :user do
        where(base, [j], fragment("?->>'user_id' = ?", j.args, ^user_id))
      else
        base
      end

    base =
      if search && search != "" do
        pattern = "%#{search}%"
        where(base, [j], fragment("?->>'url' ILIKE ?", j.args, ^pattern))
      else
        base
      end

    total = Repo.aggregate(base, :count, :id)
    total_pages = max(ceil(total / page_size), 1)
    offset = (page - 1) * page_size

    jobs =
      base
      |> limit(^page_size)
      |> offset(^offset)
      |> Repo.all()

    %{
      jobs: jobs,
      page: page,
      page_size: page_size,
      total: total,
      total_pages: total_pages
    }
  end

  @doc """
  Returns aggregate-only stats with no user detail.
  """
  def public_summary do
    %{
      source_count: Repo.aggregate(Source, :count, :id),
      document_count: Repo.aggregate(Document, :count, :id),
      chunk_count: Repo.aggregate(Chunk, :count, :id)
    }
  end

  # --- Private ---

  defp count_sources(user_id, :user) do
    from(s in Source,
      join: c in Collection,
      on: c.id == s.collection_id,
      where: c.user_id == ^user_id
    )
    |> Repo.aggregate(:count, :id)
  end

  defp count_sources(_user_id, :all), do: Repo.aggregate(Source, :count, :id)

  defp count_documents(user_id, :user) do
    from(d in Document, where: d.user_id == ^user_id)
    |> Repo.aggregate(:count, :id)
  end

  defp count_documents(_user_id, :all), do: Repo.aggregate(Document, :count, :id)

  defp count_chunks(user_id, :user) do
    from(c in Chunk,
      join: d in Document,
      on: d.id == c.document_id,
      where: d.user_id == ^user_id
    )
    |> Repo.aggregate(:count, :id)
  end

  defp count_chunks(_user_id, :all), do: Repo.aggregate(Chunk, :count, :id)

  defp count_jobs(user_id, :user, state) do
    from(j in "oban_jobs",
      where:
        j.queue == "rag_ingest" and
          j.state == ^state and
          fragment("?->>'user_id' = ?", j.args, ^user_id)
    )
    |> Repo.aggregate(:count, :id)
  end

  defp count_jobs(_user_id, :all, state) do
    from(j in "oban_jobs",
      where: j.queue == "rag_ingest" and j.state == ^state
    )
    |> Repo.aggregate(:count, :id)
  end

  defp count_embed_requests(user_id, :user, nil) do
    from(e in EmbeddingRequest, where: e.user_id == ^user_id)
    |> Repo.aggregate(:count, :id)
  end

  defp count_embed_requests(user_id, :user, status) do
    from(e in EmbeddingRequest, where: e.user_id == ^user_id and e.status == ^status)
    |> Repo.aggregate(:count, :id)
  end

  defp count_embed_requests(_user_id, :all, nil) do
    Repo.aggregate(EmbeddingRequest, :count, :id)
  end

  defp count_embed_requests(_user_id, :all, status) do
    from(e in EmbeddingRequest, where: e.status == ^status)
    |> Repo.aggregate(:count, :id)
  end

  defp job_counts_since(user_id, scope, cutoff) do
    base =
      from(j in "oban_jobs",
        where: j.queue == "rag_ingest" and j.inserted_at >= ^cutoff
      )

    base =
      if scope == :user do
        where(base, [j], fragment("?->>'user_id' = ?", j.args, ^user_id))
      else
        base
      end

    total = Repo.aggregate(base, :count, :id)

    failed =
      base
      |> where([j], j.state == "discarded")
      |> Repo.aggregate(:count, :id)

    retried =
      base
      |> where([j], j.attempt > 1)
      |> Repo.aggregate(:count, :id)

    {total, failed, retried}
  end

  defp embed_counts_since(user_id, scope, cutoff) do
    base = from(e in EmbeddingRequest, where: e.inserted_at >= ^cutoff)

    base =
      if scope == :user do
        where(base, [e], e.user_id == ^user_id)
      else
        base
      end

    total = Repo.aggregate(base, :count, :id)

    failed =
      base
      |> where([e], e.status == "error")
      |> Repo.aggregate(:count, :id)

    {total, failed}
  end

  defp maybe_scope_collection(query, user_id, :user) do
    where(query, [c, d, s, coll], coll.user_id == ^user_id)
  end

  defp maybe_scope_collection(query, _user_id, :all), do: query

  defp window_cutoff(:hour), do: DateTime.utc_now() |> DateTime.add(-3600, :second)
  defp window_cutoff(:day), do: DateTime.utc_now() |> DateTime.add(-86_400, :second)
  defp window_cutoff(:week), do: DateTime.utc_now() |> DateTime.add(-604_800, :second)

  @doc false
  def safe_rate(_numerator, 0), do: 0.0
  def safe_rate(numerator, denominator), do: Float.round(numerator / denominator * 100, 1)
end
