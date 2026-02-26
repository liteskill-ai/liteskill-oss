# Liteskill

Liteskill is an event-sourced chat application built with Phoenix 1.8 and Elixir. It provides multi-model LLM integration, MCP tool support, RAG (Retrieval-Augmented Generation), an agent studio, collaborative reports, a built-in wiki, and scheduled agent runs.

## Key Capabilities

- **Multi-model chat** — Connect any LLM provider (AWS Bedrock, OpenRouter, OpenAI-compatible endpoints) and switch models per conversation.
- **MCP tool calling** — Register MCP servers and let the LLM call external tools during conversation streaming, with optional user approval.
- **RAG** — Ingest documents, generate embeddings via Cohere/OpenAI, and augment conversations with semantic search results.
- **Agent Studio** — Define reusable AI agents with system prompts, model assignments, and scoped tool/data-source access via ACLs.
- **Teams & Runs** — Compose agents into teams with topologies (sequential, parallel, supervisor) and execute them as runs.
- **Reports** — Structured documents with nested sections, markdown rendering, and a comment/review workflow.
- **Wiki** — Built-in collaborative wiki with hierarchical pages, ACL-based sharing, and automatic RAG indexing.
- **Schedules** — Cron-based recurring execution of agent runs.
- **Usage tracking** — Per-user, per-model, per-conversation token and cost accounting.

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Language | Elixir 1.18 / Erlang/OTP 28 |
| Web framework | Phoenix 1.8.3, Phoenix LiveView 1.1 |
| HTTP server | Bandit |
| Database | PostgreSQL 16 with pgvector |
| HTTP client | Req + ReqLLM |
| Background jobs | Oban |
| CSS | Tailwind CSS v4 |
| Auth | Ueberauth (OIDC) + Argon2 (password) |
| Encryption | AES-256-GCM via `Liteskill.Crypto` |

Current version: **0.2.37**
