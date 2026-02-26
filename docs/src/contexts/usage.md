# Usage Context

`Liteskill.Usage` records and queries LLM token usage and costs.

## Boundary

```elixir
use Boundary,
  top_level?: true,
  deps: [Liteskill.Groups, Liteskill.LlmModels, Liteskill.Rag],
  exports: [UsageRecord, CostCalculator]
```

## Recording Usage

| Function | Description |
|----------|-------------|
| `record_usage(attrs)` | Inserts a raw usage record |
| `record_from_response(usage, opts)` | Builds and inserts from an API response map |

`record_from_response/2` resolves costs via `CostCalculator`, assembles all fields, and inserts. No-ops when `user_id` is nil.

Each record tracks: `input_tokens`, `output_tokens`, `total_tokens`, `reasoning_tokens`, `cached_tokens`, `cache_creation_tokens`, `input_cost`, `output_cost`, `reasoning_cost`, `total_cost`, `latency_ms`, `call_type`, and `tool_round`.

## Aggregation Queries

| Function | Description |
|----------|-------------|
| `usage_by_conversation(conversation_id)` | Totals for a conversation |
| `usage_by_user(user_id, opts)` | Totals for a user (with time filters) |
| `usage_by_user_and_model(user_id, opts)` | Per-model breakdown for a user |
| `usage_by_group(group_id, opts)` | Totals for all group members |
| `usage_by_groups(group_ids, opts)` | Batch group totals |
| `usage_by_run(run_id)` | Totals for a run |
| `usage_by_run_since(run_id, since)` | Run usage since a timestamp |
| `usage_by_run_and_model(run_id)` | Per-model breakdown for a run |
| `usage_summary(opts)` | Flexible query builder with grouping |
| `instance_totals(opts)` | Instance-wide totals |
| `daily_totals(opts)` | Daily aggregates |

## Cost Limits

- `check_cost_limit(:conversation, id, limit)` — Checks if conversation cost exceeds limit
- `check_cost_limit(:run, id, limit)` — Checks if run cost exceeds limit

## Cost Calculator

`Liteskill.Usage.CostCalculator` computes costs from token counts and model pricing:

- Resolves per-model input/output rates from the `LlmModel` record
- Calculates separate costs for input, output, and reasoning tokens
- Handles cached token pricing

## Embedding Usage

Separate tracking for embedding API calls:

- `embedding_totals(opts)` — Aggregate embedding usage
