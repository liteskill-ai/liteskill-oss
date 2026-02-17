defmodule Liteskill.Usage do
  use Boundary,
    top_level?: true,
    deps: [Liteskill.Groups, Liteskill.LlmModels, Liteskill.Rag],
    exports: [UsageRecord, CostCalculator]

  @moduledoc """
  Context for recording and querying LLM token usage.

  Usage records are stored in a dedicated projection table, independent
  of the event store, for efficient aggregation queries by user,
  conversation, model, and time period.
  """

  import Ecto.Query

  alias Liteskill.Repo
  alias Liteskill.Usage.CostCalculator
  alias Liteskill.Usage.UsageRecord

  require Logger

  @doc """
  Records a single LLM API call's usage.

  Required attrs: `:user_id`, `:model_id`, `:call_type`.
  """
  def record_usage(attrs) when is_map(attrs) do
    %UsageRecord{}
    |> UsageRecord.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Builds and records a usage record from an API usage map.

  Resolves costs via `CostCalculator`, assembles all fields, and inserts.
  No-ops (returns `:ok`) when `user_id` is nil.

  ## Options

    * `:user_id` - (required for recording) User who made the call
    * `:llm_model` - `%LlmModel{}` struct for model_id/rates lookup
    * `:model_id` - Fallback model ID string (used when no llm_model)
    * `:conversation_id` - Optional conversation association
    * `:message_id` - Optional message association
    * `:run_id` - Optional run association
    * `:call_type` - `"stream"` or `"complete"` (required)
    * `:latency_ms` - Response latency in milliseconds
    * `:tool_round` - Tool calling round number (default 0)
  """
  def record_from_response(usage, opts) when is_map(usage) and is_list(opts) do
    user_id = Keyword.get(opts, :user_id)

    if user_id do
      llm_model = Keyword.get(opts, :llm_model)
      input_tokens = usage[:input_tokens] || 0
      output_tokens = usage[:output_tokens] || 0

      {input_cost, output_cost, total_cost} =
        CostCalculator.resolve_costs(usage, llm_model, input_tokens, output_tokens)

      model_id =
        case llm_model do
          %{model_id: id} -> id
          _ -> Keyword.get(opts, :model_id, "unknown")
        end

      llm_model_id =
        case llm_model do
          %{id: id} -> id
          _ -> nil
        end

      attrs = %{
        user_id: user_id,
        conversation_id: Keyword.get(opts, :conversation_id),
        message_id: Keyword.get(opts, :message_id),
        run_id: Keyword.get(opts, :run_id),
        model_id: model_id,
        llm_model_id: llm_model_id,
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        total_tokens: usage[:total_tokens] || 0,
        reasoning_tokens: usage[:reasoning_tokens] || 0,
        cached_tokens: usage[:cached_tokens] || 0,
        cache_creation_tokens: usage[:cache_creation_tokens] || 0,
        input_cost: input_cost,
        output_cost: output_cost,
        reasoning_cost: CostCalculator.to_decimal(usage[:reasoning_cost]),
        total_cost: total_cost,
        latency_ms: Keyword.get(opts, :latency_ms),
        call_type: Keyword.fetch!(opts, :call_type),
        tool_round: Keyword.get(opts, :tool_round, 0)
      }

      case record_usage(attrs) do
        {:ok, _} ->
          :ok

        # coveralls-ignore-start
        {:error, changeset} ->
          Logger.warning("Failed to record usage: #{inspect(changeset.errors)}")
          :ok
          # coveralls-ignore-stop
      end
    else
      :ok
    end
  end

  def record_from_response(nil, _opts), do: :ok

  @doc """
  Returns aggregated usage for a conversation.

  Returns a map with summed token counts and costs.
  """
  def usage_by_conversation(conversation_id) do
    UsageRecord
    |> where([r], r.conversation_id == ^conversation_id)
    |> select([r], %{
      input_tokens: coalesce(sum(r.input_tokens), 0),
      output_tokens: coalesce(sum(r.output_tokens), 0),
      total_tokens: coalesce(sum(r.total_tokens), 0),
      reasoning_tokens: coalesce(sum(r.reasoning_tokens), 0),
      cached_tokens: coalesce(sum(r.cached_tokens), 0),
      input_cost: sum(r.input_cost),
      output_cost: sum(r.output_cost),
      total_cost: sum(r.total_cost),
      call_count: count(r.id)
    })
    |> Repo.one()
  end

  @doc """
  Returns aggregated usage for a user.

  ## Options

    * `:from` - Start datetime (inclusive)
    * `:to` - End datetime (exclusive)
  """
  def usage_by_user(user_id, opts \\ []) do
    UsageRecord
    |> where([r], r.user_id == ^user_id)
    |> apply_time_filters(opts)
    |> select([r], %{
      input_tokens: coalesce(sum(r.input_tokens), 0),
      output_tokens: coalesce(sum(r.output_tokens), 0),
      total_tokens: coalesce(sum(r.total_tokens), 0),
      reasoning_tokens: coalesce(sum(r.reasoning_tokens), 0),
      cached_tokens: coalesce(sum(r.cached_tokens), 0),
      input_cost: sum(r.input_cost),
      output_cost: sum(r.output_cost),
      total_cost: sum(r.total_cost),
      call_count: count(r.id)
    })
    |> Repo.one()
  end

  @doc """
  Returns usage for a user grouped by model.

  ## Options

    * `:from` - Start datetime (inclusive)
    * `:to` - End datetime (exclusive)
  """
  def usage_by_user_and_model(user_id, opts \\ []) do
    UsageRecord
    |> where([r], r.user_id == ^user_id)
    |> apply_time_filters(opts)
    |> group_by([r], r.model_id)
    |> select([r], %{
      model_id: r.model_id,
      input_tokens: coalesce(sum(r.input_tokens), 0),
      output_tokens: coalesce(sum(r.output_tokens), 0),
      total_tokens: coalesce(sum(r.total_tokens), 0),
      input_cost: sum(r.input_cost),
      output_cost: sum(r.output_cost),
      total_cost: sum(r.total_cost),
      call_count: count(r.id)
    })
    |> order_by([r], desc: coalesce(sum(r.total_tokens), 0))
    |> Repo.all()
  end

  @doc """
  Flexible usage query builder.

  ## Options

    * `:user_id` - Filter by user
    * `:conversation_id` - Filter by conversation
    * `:model_id` - Filter by model ID string
    * `:from` - Start datetime (inclusive)
    * `:to` - End datetime (exclusive)
    * `:group_by` - `:model_id`, `:user_id`, or `:conversation_id`
  """
  def usage_summary(opts \\ []) do
    query =
      UsageRecord
      |> apply_filters(opts)
      |> apply_time_filters(opts)

    case opts[:group_by] do
      :model_id ->
        query
        |> group_by([r], r.model_id)
        |> select([r], %{
          model_id: r.model_id,
          input_tokens: coalesce(sum(r.input_tokens), 0),
          output_tokens: coalesce(sum(r.output_tokens), 0),
          total_tokens: coalesce(sum(r.total_tokens), 0),
          input_cost: sum(r.input_cost),
          output_cost: sum(r.output_cost),
          total_cost: sum(r.total_cost),
          call_count: count(r.id)
        })
        |> Repo.all()

      :user_id ->
        query
        |> group_by([r], r.user_id)
        |> select([r], %{
          user_id: r.user_id,
          input_tokens: coalesce(sum(r.input_tokens), 0),
          output_tokens: coalesce(sum(r.output_tokens), 0),
          total_tokens: coalesce(sum(r.total_tokens), 0),
          input_cost: sum(r.input_cost),
          output_cost: sum(r.output_cost),
          total_cost: sum(r.total_cost),
          call_count: count(r.id)
        })
        |> Repo.all()

      :conversation_id ->
        query
        |> group_by([r], r.conversation_id)
        |> select([r], %{
          conversation_id: r.conversation_id,
          input_tokens: coalesce(sum(r.input_tokens), 0),
          output_tokens: coalesce(sum(r.output_tokens), 0),
          total_tokens: coalesce(sum(r.total_tokens), 0),
          input_cost: sum(r.input_cost),
          output_cost: sum(r.output_cost),
          total_cost: sum(r.total_cost),
          call_count: count(r.id)
        })
        |> Repo.all()

      nil ->
        query
        |> select([r], %{
          input_tokens: coalesce(sum(r.input_tokens), 0),
          output_tokens: coalesce(sum(r.output_tokens), 0),
          total_tokens: coalesce(sum(r.total_tokens), 0),
          input_cost: sum(r.input_cost),
          output_cost: sum(r.output_cost),
          total_cost: sum(r.total_cost),
          call_count: count(r.id)
        })
        |> Repo.one()
    end
  end

  @doc """
  Returns aggregated usage for all members of a group.

  ## Options

    * `:from` - Start datetime (inclusive)
    * `:to` - End datetime (exclusive)
  """
  def usage_by_group(group_id, opts \\ []) do
    member_subquery =
      from(gm in Liteskill.Groups.GroupMembership,
        where: gm.group_id == ^group_id,
        select: gm.user_id
      )

    UsageRecord
    |> where([r], r.user_id in subquery(member_subquery))
    |> apply_time_filters(opts)
    |> select([r], %{
      input_tokens: coalesce(sum(r.input_tokens), 0),
      output_tokens: coalesce(sum(r.output_tokens), 0),
      total_tokens: coalesce(sum(r.total_tokens), 0),
      reasoning_tokens: coalesce(sum(r.reasoning_tokens), 0),
      cached_tokens: coalesce(sum(r.cached_tokens), 0),
      input_cost: sum(r.input_cost),
      output_cost: sum(r.output_cost),
      total_cost: sum(r.total_cost),
      call_count: count(r.id)
    })
    |> Repo.one()
  end

  @doc """
  Returns aggregated usage for multiple groups in a single query.

  Returns a map of `group_id => usage_map`. Groups with no usage
  are included with zeroed values.

  ## Options

    * `:from` - Start datetime (inclusive)
    * `:to` - End datetime (exclusive)
  """
  def usage_by_groups(group_ids, opts \\ []) when is_list(group_ids) do
    if group_ids == [] do
      %{}
    else
      results =
        UsageRecord
        |> join(:inner, [r], gm in Liteskill.Groups.GroupMembership,
          on: r.user_id == gm.user_id and gm.group_id in ^group_ids
        )
        |> apply_time_filters(opts)
        |> group_by([r, gm], gm.group_id)
        |> select([r, gm], %{
          group_id: gm.group_id,
          input_tokens: coalesce(sum(r.input_tokens), 0),
          output_tokens: coalesce(sum(r.output_tokens), 0),
          total_tokens: coalesce(sum(r.total_tokens), 0),
          reasoning_tokens: coalesce(sum(r.reasoning_tokens), 0),
          cached_tokens: coalesce(sum(r.cached_tokens), 0),
          input_cost: sum(r.input_cost),
          output_cost: sum(r.output_cost),
          total_cost: sum(r.total_cost),
          call_count: count(r.id)
        })
        |> Repo.all()

      result_map = Map.new(results, fn row -> {row.group_id, Map.delete(row, :group_id)} end)

      empty = %{
        input_tokens: 0,
        output_tokens: 0,
        total_tokens: 0,
        reasoning_tokens: 0,
        cached_tokens: 0,
        input_cost: nil,
        output_cost: nil,
        total_cost: nil,
        call_count: 0
      }

      Map.new(group_ids, fn id -> {id, Map.get(result_map, id, empty)} end)
    end
  end

  @doc """
  Returns aggregated usage for a run.
  """
  def usage_by_run(run_id) do
    UsageRecord
    |> where([r], r.run_id == ^run_id)
    |> select([r], %{
      input_tokens: coalesce(sum(r.input_tokens), 0),
      output_tokens: coalesce(sum(r.output_tokens), 0),
      total_tokens: coalesce(sum(r.total_tokens), 0),
      reasoning_tokens: coalesce(sum(r.reasoning_tokens), 0),
      cached_tokens: coalesce(sum(r.cached_tokens), 0),
      input_cost: sum(r.input_cost),
      output_cost: sum(r.output_cost),
      total_cost: sum(r.total_cost),
      call_count: count(r.id)
    })
    |> Repo.one()
  end

  @doc """
  Returns aggregated usage for a run since a given timestamp.

  Useful for per-stage usage tracking: capture `DateTime.utc_now()` before
  an agent runs, then call this after it completes to get that stage's usage.
  """
  def usage_by_run_since(run_id, %DateTime{} = since) do
    naive_since = DateTime.to_naive(since)

    UsageRecord
    |> where([r], r.run_id == ^run_id and r.inserted_at >= ^naive_since)
    |> select([r], %{
      input_tokens: coalesce(sum(r.input_tokens), 0),
      output_tokens: coalesce(sum(r.output_tokens), 0),
      cached_tokens: coalesce(sum(r.cached_tokens), 0),
      total_cost: sum(r.total_cost),
      call_count: count(r.id)
    })
    |> Repo.one()
  end

  @doc """
  Returns usage for a run grouped by model.
  """
  def usage_by_run_and_model(run_id) do
    UsageRecord
    |> where([r], r.run_id == ^run_id)
    |> group_by([r], r.model_id)
    |> select([r], %{
      model_id: r.model_id,
      input_tokens: coalesce(sum(r.input_tokens), 0),
      output_tokens: coalesce(sum(r.output_tokens), 0),
      total_tokens: coalesce(sum(r.total_tokens), 0),
      input_cost: sum(r.input_cost),
      output_cost: sum(r.output_cost),
      total_cost: sum(r.total_cost),
      call_count: count(r.id)
    })
    |> order_by([r], desc: coalesce(sum(r.total_tokens), 0))
    |> Repo.all()
  end

  @doc """
  Checks if accumulated cost exceeds the given limit.

  Returns `:ok` when under or at the limit, or
  `{:error, :cost_limit_exceeded, current_cost}` when exceeded.
  Always returns `:ok` when `cost_limit` is `nil`.
  """
  def check_cost_limit(_type, _entity_id, nil), do: :ok

  def check_cost_limit(:conversation, conversation_id, cost_limit) do
    usage = usage_by_conversation(conversation_id)
    do_check_cost(usage, cost_limit)
  end

  def check_cost_limit(:run, run_id, cost_limit) do
    usage = usage_by_run(run_id)
    do_check_cost(usage, cost_limit)
  end

  defp do_check_cost(usage, cost_limit) do
    current = usage.total_cost || Decimal.new(0)

    if Decimal.compare(current, cost_limit) in [:lt, :eq] do
      :ok
    else
      {:error, :cost_limit_exceeded, current}
    end
  end

  @doc """
  Returns instance-wide usage totals.

  ## Options

    * `:from` - Start datetime (inclusive)
    * `:to` - End datetime (exclusive)
  """
  def instance_totals(opts \\ []) do
    UsageRecord
    |> apply_time_filters(opts)
    |> select([r], %{
      input_tokens: coalesce(sum(r.input_tokens), 0),
      output_tokens: coalesce(sum(r.output_tokens), 0),
      total_tokens: coalesce(sum(r.total_tokens), 0),
      reasoning_tokens: coalesce(sum(r.reasoning_tokens), 0),
      cached_tokens: coalesce(sum(r.cached_tokens), 0),
      input_cost: sum(r.input_cost),
      output_cost: sum(r.output_cost),
      total_cost: sum(r.total_cost),
      call_count: count(r.id)
    })
    |> Repo.one()
  end

  @doc """
  Returns daily usage totals for the given time range.

  ## Options

    * `:from` - Start datetime (inclusive)
    * `:to` - End datetime (exclusive)
  """
  def daily_totals(opts \\ []) do
    UsageRecord
    |> apply_filters(opts)
    |> apply_time_filters(opts)
    |> group_by([r], fragment("date_trunc('day', ?)", r.inserted_at))
    |> select([r], %{
      date: fragment("date_trunc('day', ?)", r.inserted_at),
      total_tokens: coalesce(sum(r.total_tokens), 0),
      input_cost: sum(r.input_cost),
      output_cost: sum(r.output_cost),
      total_cost: sum(r.total_cost),
      call_count: count(r.id)
    })
    |> order_by([r], asc: fragment("date_trunc('day', ?)", r.inserted_at))
    |> Repo.all()
  end

  defp apply_filters(query, opts) do
    query
    |> maybe_filter(:user_id, opts[:user_id])
    |> maybe_filter(:conversation_id, opts[:conversation_id])
    |> maybe_filter(:model_id, opts[:model_id])
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, :user_id, val), do: where(query, [r], r.user_id == ^val)

  defp maybe_filter(query, :conversation_id, val),
    do: where(query, [r], r.conversation_id == ^val)

  defp maybe_filter(query, :model_id, val), do: where(query, [r], r.model_id == ^val)

  defp apply_time_filters(query, opts) do
    query
    |> maybe_from(opts[:from])
    |> maybe_to(opts[:to])
  end

  defp maybe_from(query, nil), do: query
  defp maybe_from(query, from), do: where(query, [r], r.inserted_at >= ^from)

  defp maybe_to(query, nil), do: query
  defp maybe_to(query, to), do: where(query, [r], r.inserted_at < ^to)

  # --- Embedding Usage ---

  alias Liteskill.LlmModels.LlmModel
  alias Liteskill.Rag.EmbeddingRequest

  @doc """
  Returns aggregate embedding usage totals.
  """
  def embedding_totals(opts \\ []) do
    EmbeddingRequest
    |> join(:left, [r], m in subquery(embedding_cost_subquery()), on: r.model_id == m.model_id)
    |> apply_time_filters(opts)
    |> select([r, m], %{
      request_count: count(r.id),
      total_tokens: coalesce(sum(r.token_count), 0),
      total_inputs: coalesce(sum(r.input_count), 0),
      avg_latency_ms: fragment("coalesce(avg(?), 0)", r.latency_ms),
      error_count: fragment("count(case when ? = 'error' then 1 end)", r.status),
      estimated_cost:
        fragment(
          "coalesce(sum(? * ? / 1000000.0), 0)",
          r.token_count,
          m.input_cost_per_million
        )
    })
    |> Repo.one()
  end

  @doc """
  Returns embedding usage grouped by model_id.
  """
  def embedding_by_model(opts \\ []) do
    EmbeddingRequest
    |> join(:left, [r], m in subquery(embedding_cost_subquery()), on: r.model_id == m.model_id)
    |> apply_time_filters(opts)
    |> group_by([r, m], r.model_id)
    |> select([r, m], %{
      model_id: r.model_id,
      request_count: count(r.id),
      total_tokens: coalesce(sum(r.token_count), 0),
      total_inputs: coalesce(sum(r.input_count), 0),
      avg_latency_ms: fragment("coalesce(avg(?), 0)", r.latency_ms),
      error_count: fragment("count(case when ? = 'error' then 1 end)", r.status),
      estimated_cost:
        fragment(
          "coalesce(sum(? * ? / 1000000.0), 0)",
          r.token_count,
          m.input_cost_per_million
        )
    })
    |> order_by([r], desc: count(r.id))
    |> Repo.all()
  end

  @doc """
  Returns embedding usage grouped by user_id.
  """
  def embedding_by_user(opts \\ []) do
    EmbeddingRequest
    |> join(:left, [r], m in subquery(embedding_cost_subquery()), on: r.model_id == m.model_id)
    |> apply_time_filters(opts)
    |> group_by([r, m], r.user_id)
    |> select([r, m], %{
      user_id: r.user_id,
      request_count: count(r.id),
      total_tokens: coalesce(sum(r.token_count), 0),
      total_inputs: coalesce(sum(r.input_count), 0),
      avg_latency_ms: fragment("coalesce(avg(?), 0)", r.latency_ms),
      error_count: fragment("count(case when ? = 'error' then 1 end)", r.status),
      estimated_cost:
        fragment(
          "coalesce(sum(? * ? / 1000000.0), 0)",
          r.token_count,
          m.input_cost_per_million
        )
    })
    |> order_by([r], desc: coalesce(sum(r.token_count), 0))
    |> Repo.all()
  end

  defp embedding_cost_subquery do
    from(m in LlmModel,
      where: m.model_type in ["embedding", "rerank"],
      distinct: m.model_id,
      select: %{model_id: m.model_id, input_cost_per_million: m.input_cost_per_million}
    )
  end
end
