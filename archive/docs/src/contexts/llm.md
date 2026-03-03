# LLM Context

`Liteskill.LLM` is the public API for LLM interactions, providing both streaming and non-streaming completions.

## Boundary

```elixir
use Boundary,
  top_level?: true,
  deps: [Liteskill.Chat, Liteskill.Aggregate, Liteskill.EventStore, Liteskill.Usage, Liteskill.LlmModels, Liteskill.LlmGateway, Liteskill.McpServers],
  exports: [StreamHandler, ToolUtils, RagContext]
```

## Non-Streaming Completions

`LLM.complete(messages, opts)` sends a single-turn completion request via ReqLLM. Used for tasks like auto-generating conversation titles.

Options:
- `:llm_model` — A `%LlmModel{}` struct with full provider config
- `:model_id` — Model ID string (requires `:provider_options`)
- `:max_tokens`, `:temperature`, `:system` — Standard LLM parameters
- `:generate_fn` — Override for testing

## Streaming

Streaming is handled by `LLM.StreamHandler`, which orchestrates:

1. Starting a streaming request via ReqLLM
2. Appending events to the conversation's event stream
3. Retrying on 429/503/408 errors and transport failures (up to 3 retries with exponential backoff)
4. Executing tool calls (auto-confirm or pause for approval)
5. Recording usage after each round

## Model Resolution

Models are configured in the database via `LlmModels` and `LlmProviders`:

- `available_models(user_id)` — Returns active inference models accessible to the user
- No hardcoded model IDs or env-var fallbacks for model selection

## LLM Gateway

The gateway provides per-provider infrastructure:

- **Circuit breaker** — Tracks failures and opens the circuit after threshold
- **Concurrency gates** — Limits concurrent requests per provider
- **Token bucket** — ETS-based rate limiting with periodic cleanup

## Usage Recording

After each streaming round, usage is recorded via `Liteskill.Usage.record_from_response/2`. This captures input tokens, output tokens, reasoning tokens, cached tokens, costs, and latency.

## RagContext

`Liteskill.LLM.RagContext` builds RAG context for prompts:

- Searches accessible RAG collections for relevant documents
- Injects top-k chunks as system context
- Tracks RAG sources for citation and traceability

## ToolUtils

`Liteskill.LLM.ToolUtils` provides shared utilities:

- Convert tool specs to ReqLLM format
- Dispatch tool execution to MCP servers
- Format tool outputs for LLM consumption
- Normalize tool call formats across providers
