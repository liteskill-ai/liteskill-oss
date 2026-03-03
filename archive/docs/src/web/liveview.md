# LiveView

Liteskill's UI is built entirely with Phoenix LiveView. The interface is composed of several LiveView modules, each handling a different feature area.

## Live Sessions

The router defines several live sessions with different auth requirements:

| Session | Mount Hook | Purpose |
|---------|-----------|---------|
| `:auth` | `redirect_if_authenticated` | Login/register (redirects away if already logged in) |
| `:setup` | `require_setup_needed` | First-time admin setup |
| `:admin` | `require_admin` | Admin-only routes |
| `:chat` | `require_authenticated` | All authenticated user routes |

## LiveView Modules

### ChatLive

The primary chat interface. Handles:

- Message list with real-time streaming updates
- Tool call approval UI
- RAG source display
- Conversation forking and editing
- Model selection

### AdminLive

Multi-tab admin dashboard with separate tab modules:

- `UsageTab` — Usage analytics and reporting
- `ServerTab` — MCP server registry
- `UsersTab` — User management and invitations
- `GroupsTab` — Group management
- `ProvidersTab` — LLM provider configuration
- `ModelsTab` — LLM model configuration
- `RolesTab` — RBAC role management
- `RagTab` — RAG settings and collection management

### SetupLive

Setup wizard used for both first-time admin setup (`/setup`) and admin re-run (`/admin/setup`).
Dual-mode: `:initial` skips existing config; `:admin_rerun` loads current DB state.

### AgentStudioLive

Agent, team, run, and schedule management with live actions:

- Agent CRUD (list, new, show, edit)
- Team composition
- Run execution with real-time log streaming
- Schedule management

### ProfileLive

User account settings: profile info, password change, personal providers and models.

### ReportsLive

Report viewing and editing with section management and comment threads.

### SourcesLive

RAG collection browser with document and chunk management.

### PipelineLive

RAG ingestion pipeline UI for URL-based document ingestion.

### WikiLive

Wiki editor and browser for creating and editing wiki spaces and pages.

### McpLive

MCP server management: CRUD, tool listing, and per-user tool selection.

### AuthLive

Login, registration, and invitation acceptance forms.

### SetupLive

First-time admin setup wizard.

## Auth Hooks

`LiteskillWeb.Plugs.LiveAuth` provides `on_mount` callbacks:

- `:require_authenticated` — Redirects to `/login` if not authenticated
- `:redirect_if_authenticated` — Redirects to `/` if already logged in
- `:require_admin` — Requires admin role
- `:require_setup_needed` — Only allows access during initial setup

## Real-Time Updates

LiveView receives real-time updates via PubSub:

- **Streaming chunks** — LLM response chunks update the UI in real-time
- **Tool call status** — Tool call progress and results
- **Run updates** — Agent run status and log entries
- **Conversation list** — New messages update conversation metadata
