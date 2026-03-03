# Conventions

## IDs and Timestamps

- **Binary UUIDs** for all primary keys
- **`:utc_datetime`** for all timestamp fields

## Schemas

- All schemas use `field :name, :string` even for text columns
- Foreign keys (e.g. `user_id`) are set programmatically, never included in `cast`

## HTTP

- **Req library only** for all HTTP calls — never httpoison, tesla, or httpc
- HTTP mocking via `Req.Test` with `plug:` option

## Boundaries

Every context uses the `Boundary` library to declare:
- `top_level?: true` — Marks it as a top-level bounded context
- `deps: [...]` — Allowed dependencies on other contexts
- `exports: [...]` — Modules visible to other contexts

The boundary compiler enforces these at compile time.

## Event Sourcing

- Events stored with **string keys** via `stringify_keys`
- Deserialized back to structs via `Events.deserialize/1`
- Stream IDs: `"conversation-<uuid>"`
- Optimistic concurrency via unique index on `(stream_id, stream_version)`

## Authorization

- All entity types share a single `entity_acls` table
- Owner ACL auto-created on resource creation
- Role hierarchy: `viewer` < `editor` < `manager` < `owner`
- RBAC permissions checked via `Liteskill.Rbac.authorize/2`

## Tailwind CSS

- **Tailwind v4** — No `tailwind.config.js`
- Uses `@import "tailwindcss"` syntax in `assets/css/app.css`

## Oban Queues

| Queue | Concurrency | Purpose |
|-------|------------|---------|
| `default` | 10 | General background jobs |
| `rag_ingest` | 5 | RAG document ingestion and embedding |
| `data_sync` | 3 | External data source synchronization |
| `agent_runs` | 3 | Agent pipeline execution |

## LLM Integration

- All LLM transport via **ReqLLM** (`req_llm ~> 1.5`)
- `ReqLLM.stream_text/3` for streaming, `ReqLLM.generate_text/3` for single-turn
- `ReqLLM.embed/3` for embeddings
- No hardcoded model IDs — all models configured in the database

## Security

- Sensitive fields encrypted at rest via `Liteskill.Crypto` (AES-256-GCM)
- SSRF protection on MCP server URLs (configurable)
- ETS-based rate limiting on API routes
- CSRF protection via Phoenix plugs
- Per-provider circuit breakers prevent cascading LLM failures
