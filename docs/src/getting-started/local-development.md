# Local Development

## Quick Start

```bash
# Install tool versions
mise install

# Install deps, create DB, run migrations, build assets
mix setup

# Start the dev server
mix phx.server
```

The app will be available at [http://localhost:4000](http://localhost:4000).

## Without Local Postgres

If you don't have PostgreSQL installed locally, use the Docker-based scripts:

```bash
# Run tests with a temporary Docker Postgres
./scripts/test-with-docker.sh test

# Full precommit with Docker Postgres
./scripts/test-with-docker.sh precommit
```

## Single-User Mode

For desktop or self-hosted single-user setups:

```bash
SINGLE_USER_MODE=true mix phx.server
```

Or use the mise task:

```bash
mise run singleuser
```

This skips the login screen and auto-provisions an admin user.

## Desktop Mode

Liteskill can run as a desktop application via Tauri (ex_tauri):

```bash
LITESKILL_DESKTOP=true mix phx.server
```

In desktop mode:

- A bundled PostgreSQL instance is started automatically
- An encryption key and secret key base are auto-generated and stored in `desktop_config.json`
- Single-user mode is enabled automatically
- Data is stored in platform-specific directories:
  - macOS: `~/Library/Application Support/Liteskill`
  - Linux: `$XDG_DATA_HOME/liteskill` (default: `~/.local/share/liteskill`)
  - Windows: `%APPDATA%/Liteskill`

## Docker Compose

For production-like local development:

```bash
export SECRET_KEY_BASE=$(openssl rand -base64 64)
export ENCRYPTION_KEY=$(openssl rand -base64 32)
docker compose up
```

The `docker-compose.yml` includes:

- **db** — `pgvector/pgvector:pg16` with persistent volume and health checks
- **app** — The Liteskill release, using `network_mode: host` for direct database access
- **migrate** — One-shot migration runner (activated with `docker compose run migrate`)
