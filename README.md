# Liteskill

A self-hosted AI chat application built with Elixir and Phoenix. Liteskill connects to AWS Bedrock LLMs (Claude by default) and supports real-time streaming, conversation branching, and external tool execution via the Model Context Protocol (MCP).

## Features

- **Streaming chat** -- Real-time token-by-token responses via Phoenix LiveView
- **MCP tool support** -- Connect external tool servers so the AI can call APIs, query databases, and more
- **Conversation forking** -- Branch any conversation at any message to explore alternate paths
- **Event sourcing** -- Every state change is an immutable event, giving you a full audit trail and the ability to replay or rebuild state
- **RAG (Retrieval-Augmented Generation)** -- Organize knowledge into collections, embed documents with Cohere embed-v4, and search with pgvector. Ingest URLs asynchronously via Oban background jobs
- **Structured reports** -- Create documents with infinitely-nested sections, collaborative comments with replies, ACL sharing, and markdown rendering
- **Dual authentication** -- OpenID Connect (SSO) and password-based registration
- **Access control** -- Share conversations, reports, and groups with specific users or groups via ACLs
- **Encrypted secrets** -- MCP API keys are encrypted at rest using AES-256-GCM

## Prerequisites

- [mise](https://mise.jdx.dev/) (manages Elixir, Erlang, and Node versions)
- PostgreSQL 14+ with the [pgvector](https://github.com/pgvector/pgvector) extension (used for RAG vector similarity search)

The project pins its toolchain via `mise.toml`:

| Tool   | Version |
|--------|---------|
| Elixir | 1.18    |
| Erlang | 28      |
| Node   | 24      |

## Getting Started

```bash
# Clone the repository
git clone https://github.com/your-org/liteskill-oss.git
cd liteskill-oss

# Install tool versions (Elixir, Erlang, Node)
mise install

# Install dependencies, create the database, run migrations, and build assets
mise exec -- mix setup

# Start the development server
mise exec -- mix phx.server
```

Visit [localhost:4000](http://localhost:4000) in your browser.

## Configuration

All runtime configuration is loaded from environment variables. Set them before starting the server or add them to a `.env` file.

### Required

| Variable                   | Description                          |
|----------------------------|--------------------------------------|
| `DATABASE_URL`             | PostgreSQL connection string         |
| `SECRET_KEY_BASE`          | Phoenix signing/encryption key       |
| `ENCRYPTION_KEY`           | Encryption key for secrets at rest   |
| `AWS_BEARER_TOKEN_BEDROCK` | AWS Bedrock bearer token for LLM access |
| `AWS_REGION`               | AWS region for Bedrock (e.g. `us-east-1`) |

### Optional

| Variable                  | Description                              | Default                                                 |
|---------------------------|------------------------------------------|---------------------------------------------------------|
| `PORT`                    | HTTP port                                | `4000`                                                  |
| `PHX_HOST`                | Public hostname                          | `example.com`                                           |
| `PHX_SERVER`              | Set to `true` to start the HTTP server   | --                                                      |
| `OIDC_ISSUER`             | OpenID Connect issuer URL                | --                                                      |
| `OIDC_CLIENT_ID`          | OIDC client ID                           | --                                                      |
| `OIDC_CLIENT_SECRET`      | OIDC client secret                       | --                                                      |

## Development

```bash
# Run the full pre-commit suite (compile, format, test)
mise exec -- mix precommit

# Run tests
mise exec -- mix test

# Run a single test file
mise exec -- mix test test/liteskill/chat_test.exs

# Reset the database
mise exec -- mix ecto.reset
```

### Project Structure

```
lib/
  liteskill/
    aggregate/          # Event sourcing: aggregate behaviour and loader
    chat/               # Chat context: conversations, messages, projector, events
    event_store/        # Append-only event store with optimistic concurrency
    llm/                # AWS Bedrock client, streaming handler, event-stream parser
    mcp_servers/        # MCP server registry and JSON-RPC 2.0 client
    rag/                # RAG: collections, sources, documents, chunking, embedding, search
    reports/            # Structured reports with nested sections and comments
    accounts/           # User management (OIDC + password auth)
    groups/             # Group memberships for ACL
    crypto/             # AES-256-GCM encryption for sensitive fields
  liteskill_web/
    live/               # LiveView: chat UI, auth
    controllers/        # REST API for conversations, groups, auth
    plugs/              # Authentication plugs
```

### Architecture

Liteskill uses event sourcing with CQRS. The write path flows through aggregates and the event store; the read path queries projection tables maintained by a GenServer projector.

```
Command -> Aggregate -> EventStore (append) -> PubSub -> Projector -> Projection Tables
                                                       -> LiveView (real-time UI updates)
```

The `ConversationAggregate` enforces a state machine: **created -> active <-> streaming -> archived**. Tool calls are handled during streaming, with support for both automatic execution and manual approval via the UI.

### RAG (Retrieval-Augmented Generation)

Liteskill includes a full RAG pipeline for grounding LLM responses in your own documents.

**Data model:** Collections → Sources → Documents → Chunks. Each collection has a configurable embedding dimension (256–1536, default 1024). Sources categorize documents by origin (`manual`, `upload`, `web`, `api`).

**Embedding and search:** Documents are chunked using a recursive text splitter that tries paragraph, line, sentence, and word boundaries before force-splitting. Chunks are embedded via Cohere embed-v4 on AWS Bedrock and stored as pgvector vectors. Search uses cosine distance with optional reranking via Cohere rerank-v3.5.

**URL ingestion:** `Rag.ingest_url/4` enqueues an Oban background job that fetches a URL, validates it contains text content (rejects binary types like images), auto-creates a source from the domain name, chunks the response body, and embeds the chunks. Jobs retry up to 3 times on transient failures; binary content is permanently rejected without retry.

### Reports

Structured documents with infinitely-nesting sections, rendered as markdown.

- **Sections** use a `path > notation` for nesting (e.g. `"Parent > Child > Grandchild"`) and are stored as a flat table with `parent_id` references
- **Comments** can be added to individual sections or at the report level, with support for replies and resolution workflows (`open` → `addressed`)
- **Batch operations** via `modify_sections/3` and `manage_comments/3` for bulk edits in a single transaction
- **ACL sharing** with owner/member roles, similar to conversation access control
- **Markdown rendering** with `render_markdown/2`, including optional comment output as blockquotes

## API

Liteskill exposes a JSON API under `/api` for programmatic access. All endpoints require session authentication.

| Method   | Path                                      | Description                 |
|----------|-------------------------------------------|-----------------------------|
| `GET`    | `/api/conversations`                      | List conversations          |
| `POST`   | `/api/conversations`                      | Create a conversation       |
| `GET`    | `/api/conversations/:id`                  | Get conversation + messages |
| `POST`   | `/api/conversations/:id/messages`         | Send a message              |
| `POST`   | `/api/conversations/:id/fork`             | Fork at a message position  |
| `POST`   | `/api/conversations/:id/acls`             | Grant user/group access     |
| `DELETE` | `/api/conversations/:id/acls/:user_id`    | Revoke access               |
| `DELETE` | `/api/conversations/:id/membership`       | Leave a shared conversation |
| `GET`    | `/api/groups`                             | List groups                 |
| `POST`   | `/api/groups`                             | Create a group              |
| `GET`    | `/api/groups/:id`                         | Get group details           |
| `DELETE` | `/api/groups/:id`                         | Delete a group              |
| `POST`   | `/api/groups/:id/members`                 | Add a member                |
| `DELETE` | `/api/groups/:id/members/:user_id`        | Remove a member             |

## Running with Docker

The quickest way to run Liteskill locally. You need [Docker](https://docs.docker.com/get-docker/) with the Compose plugin.

### Quick start (Docker Compose)

**1. Create a `.env` file**

Liteskill requires secret keys and AWS Bedrock credentials. Generate the secrets and add your AWS config:

```bash
cat <<EOF > .env
SECRET_KEY_BASE=$(openssl rand -base64 64 | tr -d '\n')
ENCRYPTION_KEY=$(openssl rand -base64 32 | tr -d '\n')
AWS_BEARER_TOKEN_BEDROCK=<your-bedrock-token>
AWS_REGION=us-east-1
EOF
```

Replace `<your-bedrock-token>` with your actual AWS Bedrock bearer token. Compose reads `.env` automatically.

**2. Start the application**

```bash
docker compose up
```

This starts PostgreSQL, waits for it to be healthy, runs database migrations, and starts the server. Visit [localhost:4000](http://localhost:4000) once the logs show the server is running. Register an account to get started — the first user is automatically made an admin.

**3. Stop everything**

```bash
docker compose down        # stop containers, keep data
docker compose down -v     # stop containers AND delete database volume
```

If any required environment variables are missing, Compose will exit with a descriptive error message telling you what to set.

### Running without Compose

If you prefer plain `docker run` or already have a PostgreSQL instance with pgvector:

```bash
# Build the image
docker build -t liteskill .

# Start the server (runs migrations automatically on startup)
docker run -d \
  -p 4000:4000 \
  -e DATABASE_URL="ecto://user:pass@host/liteskill" \
  -e SECRET_KEY_BASE="$(openssl rand -base64 64 | tr -d '\n')" \
  -e ENCRYPTION_KEY="$(openssl rand -base64 32 | tr -d '\n')" \
  -e AWS_BEARER_TOKEN_BEDROCK="<your-bedrock-token>" \
  -e AWS_REGION="us-east-1" \
  -e PHX_HOST="localhost" \
  liteskill
```

If your PostgreSQL is on the host machine, add `--network host` instead of `-p 4000:4000` and use `localhost` in `DATABASE_URL`.

### Environment variable reference

All configuration is loaded at startup from environment variables. See the [Configuration](#configuration) section above for the full list. The database **must** have the [pgvector](https://github.com/pgvector/pgvector) extension available — the `pgvector/pgvector:pg16` image used in `docker-compose.yml` includes it.

### Image tags

CI automatically builds and pushes images to Docker Hub on every push to `main` and on version tags:

| Event | Tags | Push? |
|-------|------|-------|
| Push to `main` | `main`, `sha-<hash>` | Yes |
| Tag `v1.2.3` | `1.2.3`, `1.2`, `latest`, `sha-<hash>` | Yes |
| Pull request | `pr-<number>` | No (build only) |

To pull a published image instead of building locally, replace `build: .` with `image: liteskill/liteskill:latest` in `docker-compose.yml`.

## Deployment

Build a release:

```bash
MIX_ENV=prod mise exec -- mix assets.deploy
MIX_ENV=prod mise exec -- mix release
```

Run it:

```bash
DATABASE_URL="ecto://..." \
SECRET_KEY_BASE="$(mix phx.gen.secret)" \
ENCRYPTION_KEY="$(mix phx.gen.secret)" \
AWS_BEARER_TOKEN_BEDROCK="<your-bedrock-token>" \
AWS_REGION="us-east-1" \
PHX_HOST="your-domain.com" \
PHX_SERVER=true \
_build/prod/rel/liteskill/bin/liteskill start
```

See the [Phoenix deployment guides](https://hexdocs.pm/phoenix/deployment.html) for more options.

## License

Apache License 2.0. See [LICENSE](LICENSE) for details.
