# Accounts Context

`Liteskill.Accounts` manages user records, authentication, and invitations.

## Boundary

```elixir
use Boundary, top_level?: true, deps: [], exports: [User, Invitation]
```

## Authentication

Liteskill supports dual authentication:

### OIDC (via Ueberauth)
- `find_or_create_from_oidc(attrs)` — Finds or creates a user by OIDC subject + issuer
- Idempotent — safe to call on every login callback

### Password (via Argon2)
- `register_user(attrs)` — Creates a user with email/password
- `authenticate_by_email_password(email, password)` — Validates credentials
- `change_password(user, current_password, new_password)` — Changes password (requires current)
- `setup_admin_password(user, password)` — First-time admin setup (no current password required)
- `set_temporary_password(user, password)` — Admin sets a temp password (forces change on login)

## User Management

| Function | Description |
|----------|-------------|
| `get_user!(id)` | Gets user by ID (raises if not found) |
| `get_user(id)` | Gets user by ID (returns nil) |
| `get_user_by_email(email)` | Finds user by email |
| `list_users()` | Lists all users ordered by email |
| `search_users(query, opts)` | Searches by name or email |
| `update_user_role(user_id, role)` | Updates role (prevents demoting root admin) |
| `update_preferences(user, new_prefs)` | Merges new preferences |

## Root Admin

On boot, `ensure_admin_user/0` creates `admin@liteskill.local` if missing and forces its role to `"admin"`.

## Single-User Mode

When `SINGLE_USER_MODE=true`, `SingleUser.auto_provision_admin/0` runs on boot to ensure the admin user is ready without manual setup.

## Invitations

- `create_invitation(email, admin_user_id)` — Creates an invite token
- `get_invitation_by_token(token)` — Looks up an invitation
- `accept_invitation(token, attrs)` — Accepts: validates token, creates user, marks as used (transactional)
- `revoke_invitation(id)` — Deletes a pending invitation
- `list_invitations()` — Lists all invitations
