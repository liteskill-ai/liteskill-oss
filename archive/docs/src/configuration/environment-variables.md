# Environment Variables

## Required (Production)

| Variable | Description |
|----------|-------------|
| `DATABASE_URL` | PostgreSQL connection string (e.g. `ecto://USER:PASS@HOST/DATABASE`) |
| `PHX_SERVER` | Set to `true` to start the HTTP server (required for releases) |

## Optional (Auto-generated if not set)

| Variable | Description |
|----------|-------------|
| `SECRET_KEY_BASE` | Phoenix secret key for cookie signing. Auto-generated and persisted to `secrets.json` on first boot if not set. Generate manually with `mix phx.gen.secret` or `openssl rand -base64 64`. |
| `LITESKILL_SECRETS_FILE` | Override the path to the auto-generated secrets file (default: platform-specific data dir) |

## Encryption (Off by Default)

| Variable | Description |
|----------|-------------|
| `LITESKILL_ENCRYPTION` | Set to `true` to enable at-rest encryption of sensitive fields |
| `ENCRYPTION_KEY` | Required when encryption is enabled. Key for AES-256-GCM (generate with `openssl rand -base64 32`) |

## Server

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `4000` | HTTP port |
| `PHX_HOST` | `example.com` | Hostname for URL generation |
| `ECTO_IPV6` | — | Set to `true` or `1` to enable IPv6 for database connections |
| `POOL_SIZE` | `10` | Database connection pool size |
| `DNS_CLUSTER_QUERY` | — | DNS query for node clustering |
| `FORCE_SSL` | — | Set to `false` to disable SSL enforcement (e.g. for local Docker) |

## Authentication

| Variable | Description |
|----------|-------------|
| `OIDC_ISSUER` | OpenID Connect issuer URL |
| `OIDC_CLIENT_ID` | OIDC client ID |
| `OIDC_CLIENT_SECRET` | OIDC client secret |

## LLM

| Variable | Description |
|----------|-------------|
| `AWS_BEARER_TOKEN_BEDROCK` | AWS Bedrock bearer token (auto-creates instance-wide provider on boot) |
| `AWS_REGION` | AWS region for Bedrock (default: `us-east-1`) |

## Mode

| Variable | Description |
|----------|-------------|
| `SINGLE_USER_MODE` | Set to `true`, `1`, or `yes` to enable single-user mode |
| `LITESKILL_DESKTOP` | Set to `true` to enable desktop mode (bundled Postgres, auto-config) |

## Desktop Mode

When `LITESKILL_DESKTOP=true`:

- A bundled PostgreSQL instance is managed automatically
- Secret key base is auto-generated and stored in `desktop_config.json`
- Single-user mode is enabled automatically
- Data is stored in platform-specific directories:
  - macOS: `~/Library/Application Support/Liteskill`
  - Linux: `$XDG_DATA_HOME/liteskill` (default: `~/.local/share/liteskill`)
  - Windows: `%APPDATA%/Liteskill`

## Docker Compose Defaults

The `docker-compose.yml` uses these defaults (overridable via shell environment):

| Variable | Default |
|----------|---------|
| `POSTGRES_USER` | `liteskill` |
| `POSTGRES_PASSWORD` | `liteskill` |
| `POSTGRES_DB` | `liteskill` |
| `PHX_HOST` | `localhost` |

`SECRET_KEY_BASE` is auto-generated on first boot if not provided. To persist across container restarts, mount a volume and set `LITESKILL_SECRETS_FILE`.
