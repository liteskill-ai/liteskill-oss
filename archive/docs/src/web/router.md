# Router

`LiteskillWeb.Router` defines all routes for the application. Routes are organized into scopes with different pipelines.

## Pipelines

| Pipeline | Purpose |
|----------|---------|
| `:browser` | HTML requests with session, CSRF, LiveView flash |
| `:api` | JSON requests with session, auth, and rate limiting (1000 req/min) |
| `:require_auth` | Requires authenticated user |

## Auth Routes (`/auth`)

| Route | Description |
|-------|-------------|
| `GET /auth/session` | Session bridge for LiveView auth |
| `DELETE /auth/logout` | Logout |
| `GET /auth/openrouter` | OpenRouter OAuth PKCE start |
| `GET /auth/openrouter/callback` | OpenRouter OAuth callback |
| `POST /auth/register` | Password registration (API) |
| `POST /auth/login` | Password login (API) |
| `GET /auth/:provider` | OIDC provider redirect |
| `GET /auth/:provider/callback` | OIDC callback |

## Public LiveView Routes

| Route | Description |
|-------|-------------|
| `/login` | Login page |
| `/register` | Registration page |
| `/invite/:token` | Invitation acceptance |
| `/setup` | First-time admin setup |

## Admin LiveView Routes

Require admin role via `require_admin` mount hook.

| Route | Description |
|-------|-------------|
| `/admin` | Admin dashboard (defaults to usage) |
| `/admin/usage` | Usage analytics |
| `/admin/servers` | MCP server registry |
| `/admin/users` | User management |
| `/admin/groups` | Group management |
| `/admin/providers` | LLM provider configuration |
| `/admin/models` | LLM model configuration |
| `/admin/roles` | Role management |
| `/admin/rag` | RAG configuration |
| `/admin/setup` | Application setup |
| `/settings/*` | Settings pages (single-user mode unified settings) |

## Authenticated LiveView Routes

### Chat

| Route | Description |
|-------|-------------|
| `/` | Main chat interface |
| `/conversations` | Conversation list |
| `/c/:conversation_id` | Single conversation |

### Profile

| Route | Description |
|-------|-------------|
| `/profile` | User info |
| `/profile/password` | Password change |
| `/profile/providers` | User LLM providers |
| `/profile/models` | User LLM models |

### Wiki

| Route | Description |
|-------|-------------|
| `/wiki` | Wiki home |
| `/wiki/:document_id` | View/edit a wiki page |
| `/wiki/:space_id/export` | Export a wiki space (browser download) |

### Sources & RAG

| Route | Description |
|-------|-------------|
| `/sources` | Source/collection list |
| `/sources/pipeline` | RAG ingestion pipeline |
| `/sources/:source_id` | Source details |
| `/sources/:source_id/:document_id` | Document details |

### MCP Servers

| Route | Description |
|-------|-------------|
| `/mcp` | MCP server management |

### Reports

| Route | Description |
|-------|-------------|
| `/reports` | Report list |
| `/reports/:report_id` | View/edit a report |

### Agent Studio

| Route | Description |
|-------|-------------|
| `/agents` | Agent Studio landing |
| `/agents/list` | Agent list |
| `/agents/new` | Create agent |
| `/agents/:agent_id` | View agent |
| `/agents/:agent_id/edit` | Edit agent |
| `/teams` | Team list |
| `/teams/new` | Create team |
| `/teams/:team_id` | View/edit team |
| `/runs` | Run list |
| `/runs/new` | Start a run |
| `/runs/:run_id` | View run details |
| `/runs/:run_id/logs/:log_id` | View run log |
| `/schedules` | Schedule list |
| `/schedules/new` | Create schedule |
| `/schedules/:schedule_id` | View/edit schedule |
