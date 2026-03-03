# Authentication

Liteskill supports two authentication methods: OIDC (OpenID Connect) and password-based.

## Session-Based Auth

All authentication is session-based. The session flow:

1. User authenticates via OIDC callback or password login
2. `user_id` is stored in the session
3. `LiteskillWeb.Plugs.Auth` loads the user from the session on each request
4. `LiteskillWeb.Plugs.LiveAuth` handles the same for LiveView mounts

## OIDC Authentication

Configured via environment variables:

- `OIDC_ISSUER` — OpenID Connect issuer URL
- `OIDC_CLIENT_ID` — Client ID
- `OIDC_CLIENT_SECRET` — Client secret

Uses Ueberauth with the OIDCC strategy. On callback, `Accounts.find_or_create_from_oidc/1` finds or creates the user by OIDC subject + issuer.

## Password Authentication

Password auth uses Argon2 for hashing (configured with `t_cost: 1, m_cost: 8` in test for speed).

### Registration
- Available at `/register` (LiveView) or `POST /auth/register` (API)
- Can be restricted to invited users only

### Login
- Available at `/login` (LiveView) or `POST /auth/login` (API)
- Returns session with user ID

### Password Changes
- Users change passwords at `/profile/password`
- Requires current password verification
- Admins can set temporary passwords that force a change on next login

## Single-User Mode

When `SINGLE_USER_MODE=true`:

- The login screen is skipped entirely
- `SingleUser.auto_user/0` returns the admin user for every request
- An admin user is auto-provisioned on boot if not present

## Invitations

Admins can create invitation tokens for specific email addresses:

1. Admin creates invitation at `/admin/users`
2. Invitation generates a unique token
3. User visits `/invite/:token` to register
4. Token is marked as used after acceptance

## OpenRouter OAuth

Liteskill supports OpenRouter OAuth PKCE flow for connecting user-level OpenRouter accounts:

1. User initiates at `GET /auth/openrouter`
2. PKCE challenge is generated and state stored in `Liteskill.OpenRouter.StateStore`
3. User authorizes on OpenRouter
4. Callback at `GET /auth/openrouter/callback` exchanges the code for credentials
