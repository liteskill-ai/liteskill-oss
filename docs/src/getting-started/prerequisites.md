# Prerequisites

## Required Tools

Liteskill uses [mise](https://mise.jdx.dev/) for tool version management. The `mise.toml` at the project root pins:

| Tool | Version |
|------|---------|
| Elixir | 1.18 |
| Erlang/OTP | 28 |
| Node.js | 24 |
| mdbook | latest |

Install mise and run `mise install` to get the correct versions.

## PostgreSQL

PostgreSQL 16 with the **pgvector** extension is required.

### Option A: Local install

Install PostgreSQL and pgvector via your system package manager. The default dev config expects:

- Host: `localhost`
- Port: `5432`
- User/password: `postgres`/`postgres`

### Option B: Docker

Use the included test script which starts a disposable Postgres container:

```bash
./scripts/test-with-docker.sh test
```

Or use the production `docker-compose.yml` which provides a `pgvector/pgvector:pg16` service.

## Quick Start (Docker Compose)

If you just want to run Liteskill without setting up a development environment:

```bash
export SECRET_KEY_BASE=$(openssl rand -base64 64)
export ENCRYPTION_KEY=$(openssl rand -base64 32)
docker compose up
```

This starts PostgreSQL with pgvector and the Liteskill application on port 4000.
