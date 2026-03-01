# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
mix setup                    # Install deps, create DB, run migrations, build assets
mix precommit                # Compile + deps.unlock + audit + format + credo + sobelow + doctor + dialyzer + test + mdbook
mix test                     # Run all tests (auto-creates/migrates DB)
mix test test/path_test.exs  # Run a single test file
mix test --failed            # Re-run previously failed tests
mix ecto.reset               # Drop + create + migrate + seed
mix phx.server               # Start dev server on localhost:4000

# Docker-based (no local Postgres needed)
./scripts/test-with-docker.sh test        # Run tests via Docker Postgres
./scripts/test-with-docker.sh precommit   # Full precommit via Docker
```

Always run `mix precommit` after completing changes.

## Architecture

Event-sourced Phoenix 1.8.3 chat app with AWS Bedrock LLM integration and MCP tool support.

### Event Sourcing Flow
Command → Aggregate → Event → EventStore (append) → PubSub broadcast → Projector → Projection tables

- **EventStore** (`Liteskill.EventStore.Postgres`): Append-only with optimistic concurrency via unique index on `(stream_id, stream_version)`. Broadcasts `{:events, stream_id, events}` on PubSub topic `"event_store:<stream_id>"`.
- **Aggregates** (`Liteskill.Aggregate.Loader`): Stateless loader, replays events (or loads from snapshot) to build state. `execute/3` handles load → command → append → apply.
- **ConversationAggregate**: State machine: `:created` → `:active` ↔ `:streaming` → `:archived`. Handles tool calls in both `:streaming` and `:active` states.
- **Projector** (`Liteskill.Chat.Projector`): GenServer in the **main supervision tree** — subscribes to PubSub and updates projection tables (conversations, messages, message_chunks, tool_calls).
- **Event serialization**: Stored with **string keys** via `stringify_keys`; deserialized back to structs via `Events.deserialize/1`.
- **Stream IDs**: `"conversation-<uuid>"`

### Contexts
- `Liteskill.Chat` — Conversation CRUD, messaging, forking, ACLs (all functions require `user_id`)
- `Liteskill.Accounts` — User management, dual auth (OIDC via ueberauth + password via Argon2)
- `Liteskill.Groups` — Group memberships used for group-based ACL authorization
- `Liteskill.McpServers` — MCP server CRUD + `Client` for JSON-RPC 2.0 `tools/list` and `tools/call`

### LLM Integration
- All LLM transport handled by **ReqLLM** (`req_llm ~> 1.5`): `ReqLLM.stream_text/3` for streaming, `ReqLLM.generate_text/3` for single-turn, `ReqLLM.embed/3` for embeddings. Provider abstraction (Bedrock, OpenAI, Anthropic, etc.) and binary event-stream parsing are delegated entirely to ReqLLM.
- `StreamHandler` (`Liteskill.LLM.StreamHandler`): Orchestrates streaming with event store integration, retry on 429/503, and tool calling loop (`auto_confirm: true` auto-executes via MCP; `false` pauses for UI confirmation).
- `LlmGenerate` (`Liteskill.Agents.Actions.LlmGenerate`): Synchronous agentic loop for agent pipelines — tool calling, context pruning, cost limits.
- `ToolUtils` (`Liteskill.LLM.ToolUtils`): Shared tool spec conversion, execution dispatch, output formatting, and tool call normalization.

### Auth & Authorization
- Session-based auth via `LiteskillWeb.Plugs.Auth` (Plug) and `LiveAuth` (LiveView mount hook)
- `authorize_conversation/2`: owner OR direct ACL OR group-based ACL
- `authorize_owner/2`: owner-only (for grant/revoke ACL operations)
- Owner ACL auto-created on `create_conversation` and `fork_conversation`

## Key Conventions

- **Binary UUIDs** for all primary keys, `:utc_datetime` for timestamps
- **Req library only** for HTTP — never httpoison/tesla/httpc
- All schemas use `field :name, :string` even for text columns
- Foreign keys (e.g. `user_id`) set programmatically, never in `cast`

## Testing

- **100% coverage required** (ExCoveralls). Use `# coveralls-ignore-start` / `# coveralls-ignore-stop` for genuinely unreachable branches.
- **Req.Test for HTTP mocking**: Pass `plug: {Req.Test, ModuleName}` option. Note: Req.Test does NOT trigger `into:` callbacks.
- **Projector runs in supervision tree** — never `start_supervised!` it in tests.
- **Process synchronization after writes**: Chat context write functions include `Process.sleep(50)`. In tests, prefer `_ = :sys.get_state(pid)` over additional sleeps.
- **Argon2 test config**: `t_cost: 1, m_cost: 8` in `config/test.exs` — keeps password hashing fast.
- **DataCase**: `use Liteskill.DataCase, async: false` (shared sandbox). **Unit tests** (aggregates, events, parsers): `use ExUnit.Case, async: true`.
- **MCP Client testing**: `plug: {Req.Test, Liteskill.McpServers.Client}`
- **Stateful stubs**: Use `Agent` for varying responses across retries. Set `backoff_ms: 1` for retry tests.

## Tooling

- **mise.toml**: Elixir 1.18, Erlang 28, Node 24
- **Tailwind CSS v4**: No `tailwind.config.js` — uses `@import "tailwindcss"` syntax in `app.css`
- **ExCoveralls skip_files**: See `coveralls.json` for excluded files (core_components, layouts, router, LiveView UI modules, etc.)
