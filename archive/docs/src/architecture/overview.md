# Architecture Overview

Liteskill is an event-sourced Phoenix application organized around bounded contexts with enforced boundaries (via the `boundary` library).

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    LiteskillWeb                          │
│  LiveView UI │ REST API │ Auth Plugs │ Rate Limiting     │
└──────────┬──────────────┬────────────────────────────────┘
           │              │
┌──────────▼──────────────▼────────────────────────────────┐
│                   Context Layer                           │
│  Chat │ Accounts │ Authorization │ Groups │ LLM │ ...    │
└──────────┬───────────────────────────────────────────────┘
           │
┌──────────▼───────────────────────────────────────────────┐
│              Infrastructure Layer                         │
│  EventStore │ Aggregate │ Crypto │ Repo │ PubSub         │
└──────────────────────────────────────────────────────────┘
```

## Bounded Contexts

Each context is a top-level `Boundary` module that declares its dependencies and exports:

| Context | Responsibility |
|---------|---------------|
| `Liteskill.Chat` | Conversations, messages, streaming, tool calls |
| `Liteskill.Accounts` | Users, OIDC, password auth, invitations |
| `Liteskill.Authorization` | Entity ACLs, role hierarchy, access queries |
| `Liteskill.Groups` | Group management and memberships |
| `Liteskill.LLM` | LLM completions, stream orchestration |
| `Liteskill.LlmProviders` | Provider CRUD, env bootstrapping |
| `Liteskill.LlmModels` | Model CRUD, provider options |
| `Liteskill.LlmGateway` | Per-provider circuit breaker, concurrency gates, token buckets |
| `Liteskill.McpServers` | MCP server CRUD, tool selection |
| `Liteskill.Rag` | Collections, sources, documents, embeddings, search |
| `Liteskill.Agents` | Agent definitions, tool/source ACLs |
| `Liteskill.Teams` | Team definitions with agent composition |
| `Liteskill.Runs` | Run execution, tasks, logs |
| `Liteskill.Reports` | Reports with nested sections and comments |
| `Liteskill.Schedules` | Cron-based recurring runs |
| `Liteskill.DataSources` | External data connectors (Google Drive, Confluence, etc.) |
| `Liteskill.Usage` | Token/cost tracking and aggregation |
| `Liteskill.Crypto` | AES-256-GCM encryption at rest |
| `Liteskill.Rbac` | Role-based permission checks |
| `Liteskill.Settings` | Application-wide settings |

## Key Design Decisions

- **Event sourcing for chat** — Conversations are modeled as event streams for full auditability and state replay. All other domains use standard CRUD with Ecto.
- **CQRS** — Write operations go through the event sourcing pipeline; reads query projection tables directly.
- **Boundary enforcement** — The `boundary` library enforces context dependencies at compile time, preventing unauthorized cross-context calls.
- **ReqLLM for all LLM transport** — No direct HTTP calls to LLM providers. ReqLLM abstracts provider differences.
- **Unified ACL table** — A single `entity_acls` table handles access control for all entity types (conversations, reports, wiki spaces, agents, etc.).
- **Oban for background jobs** — Embedding, data source sync, and agent runs are processed as Oban jobs with configurable queues and concurrency.
