# Database

Liteskill uses PostgreSQL 16 with the **pgvector** extension for vector similarity search.

## Conventions

- **Binary UUIDs** for all primary keys
- **`:utc_datetime`** for all timestamps
- All schemas use `field :name, :string` even for text columns
- Foreign keys (e.g. `user_id`) are set programmatically, never in `cast`
- Custom Postgrex types registered via `Liteskill.Repo.PostgrexTypes`

## Key Tables

### Event Store
- `events` — Append-only event log with `(stream_id, stream_version)` unique index
- `snapshots` — Aggregate snapshots for performance

### Projections (Chat)
- `conversations` — Current conversation state (stream_id, title, status, model, message_count)
- `messages` — Projected messages (role, content, status, token counts, position)
- `message_chunks` — Streaming chunks (delta_text, delta_type, chunk_index)
- `tool_calls` — Tool call records (name, arguments, status, result)

### Accounts & Auth
- `users` — User records (OIDC and password auth)
- `invitations` — Admin-created invite tokens
- `entity_acls` — Unified ACL table for all entity types
- `rbac_roles` / `rbac_role_permissions` / `rbac_user_roles` — Role-based access control

### LLM
- `llm_providers` — Provider configurations (API keys encrypted, regions, types)
- `llm_models` — Model definitions linked to providers (costs, context window, type)
- `usage_records` — Token/cost tracking per API call

### RAG
- `rag_collections` — Top-level grouping for embeddings (configurable dimension)
- `rag_sources` — Sources within collections
- `rag_documents` — Documents to be chunked and embedded
- `rag_chunks` — Chunked text with pgvector embeddings

### Data Sources
- `data_sources` — External connectors (Google Drive, Confluence, Jira, GitHub, GitLab, SharePoint)
- `data_source_documents` — Documents synced from connectors

### Agents & Teams
- `agent_definitions` — AI agent configurations (backstory, strategy, model)
- `team_definitions` — Agent team compositions
- `team_members` — Position-ordered team membership with roles

### Runs
- `runs` — Agent/team execution records (status, prompt, topology)
- `run_tasks` — Individual task tracking within a run
- `run_logs` — Structured execution logs (level, step, message, metadata)

### Features
- `reports` / `report_sections` / `section_comments` — Structured report documents
- `schedules` — Cron-based scheduled runs
- `mcp_servers` — MCP server registrations
- `user_tool_selections` — Per-user MCP server selections
- `settings` — Application-wide settings

### Background Jobs
- `oban_jobs` / `oban_peers` — Oban background job queue tables
