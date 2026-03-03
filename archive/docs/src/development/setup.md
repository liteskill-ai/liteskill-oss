# Development Setup

## Prerequisites

1. Install [mise](https://mise.jdx.dev/)
2. Clone the repository
3. Run `mise install` to get Elixir 1.18, Erlang/OTP 28, Node.js 24, and mdbook

## Setup

```bash
mix setup
```

This runs:
1. `deps.get` — Install Elixir dependencies
2. `ecto.create` — Create the database
3. `ecto.migrate` — Run migrations
4. `run priv/repo/seeds.exs` — Seed data
5. `npm install --prefix assets` — Install Node dependencies
6. `tailwind.install --if-missing` — Install Tailwind
7. `esbuild.install --if-missing` — Install esbuild
8. `gen.jr_prompt` — Generate JSON render prompt
9. Compile and build assets

## Database Reset

```bash
mix ecto.reset
```

Drops, creates, migrates, and seeds the database.

## Running the Server

```bash
mix phx.server
```

Visit [http://localhost:4000](http://localhost:4000).

## Docker-Based Development

If you don't have PostgreSQL installed locally:

```bash
# Run tests with Docker Postgres
./scripts/test-with-docker.sh test

# Full precommit with Docker Postgres
./scripts/test-with-docker.sh precommit
```

The script starts a temporary `pgvector/pgvector:pg16` container, sets `DATABASE_URL`, runs the specified command, and cleans up after.

## Building the Docker Image

```bash
docker build -t liteskill .
```

The multi-stage Dockerfile:

1. **Stage 0** — Copies Node.js binaries from `node:24-bookworm-slim`
2. **Stage 1 (Builder)** — Compiles the Elixir release with `mix release liteskill`
3. **Stage 2 (Runtime)** — Minimal Debian image with the release binary

## Running with Docker Compose

```bash
export SECRET_KEY_BASE=$(openssl rand -base64 64)
export ENCRYPTION_KEY=$(openssl rand -base64 32)
docker compose up
```

This starts:
- **db** — PostgreSQL 16 with pgvector
- **app** — Liteskill release with host networking

To run migrations separately:

```bash
docker compose run --rm migrate
```
