# API

Liteskill provides a JSON REST API at `/api` for programmatic access.

## Authentication

API routes require session-based authentication. The `:api` pipeline:

1. Accepts JSON (`"application/json"`)
2. Fetches session
3. Loads current user via `LiteskillWeb.Plugs.Auth`
4. Applies rate limiting (1000 requests per 60 seconds)

The `:require_auth` pipeline then verifies an authenticated user is present.

## Endpoints

### Conversations

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/conversations` | List conversations |
| `POST` | `/api/conversations` | Create a conversation |
| `GET` | `/api/conversations/:id` | Get a conversation |
| `POST` | `/api/conversations/:id/messages` | Send a message |
| `POST` | `/api/conversations/:id/fork` | Fork a conversation |
| `POST` | `/api/conversations/:id/acls` | Grant access |
| `DELETE` | `/api/conversations/:id/acls/:target_user_id` | Revoke access |
| `DELETE` | `/api/conversations/:id/membership` | Leave conversation |

### Groups

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/groups` | List groups |
| `POST` | `/api/groups` | Create a group |
| `GET` | `/api/groups/:id` | Get a group |
| `DELETE` | `/api/groups/:id` | Delete a group |
| `POST` | `/api/groups/:id/members` | Add a member |
| `DELETE` | `/api/groups/:id/members/:user_id` | Remove a member |

## Rate Limiting

The API uses an ETS-based rate limiter (`LiteskillWeb.Plugs.RateLimiter`) with:

- **Limit**: 1000 requests per window
- **Window**: 60 seconds
- Periodic sweeper cleans stale ETS entries
