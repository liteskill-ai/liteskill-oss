defmodule Liteskill.Accounts do
  @moduledoc """
  The Accounts context. Manages user records created from OIDC or password authentication.
  """
  use Boundary, top_level?: true, deps: [], exports: [User, Invitation, UserSession, AuthEvent]

  alias Liteskill.Accounts.AuthEvent
  alias Liteskill.Accounts.Invitation
  alias Liteskill.Accounts.User
  alias Liteskill.Accounts.UserSession
  alias Liteskill.Repo

  import Ecto.Query

  @admin_email User.admin_email()

  @doc """
  Ensures the root admin user exists. Called on application boot.
  Creates admin@liteskill.local if missing; forces role to "admin" if changed.
  """
  def ensure_admin_user do
    email = User.admin_email()

    case get_user_by_email(email) do
      nil ->
        %User{email: email, name: "Admin", role: "admin"}
        |> Repo.insert!()

      %User{role: "admin"} = user ->
        user

      user ->
        user
        |> User.role_changeset(%{role: "admin"})
        |> Repo.update!()
    end
  end

  @doc """
  Finds an existing user by OIDC subject+issuer or creates a new one.
  Idempotent -- safe to call on every login callback.
  """
  def find_or_create_from_oidc(attrs) do
    sub = Map.fetch!(attrs, :oidc_sub)
    issuer = Map.fetch!(attrs, :oidc_issuer)

    case Repo.one(from u in User, where: u.oidc_sub == ^sub and u.oidc_issuer == ^issuer) do
      nil ->
        %User{}
        |> User.changeset(Map.new(attrs))
        |> Repo.insert()

      user ->
        {:ok, user}
    end
  end

  @doc """
  Finds an existing user by email (for SAML account linking) or creates a new one.
  When an existing user is found by email, updates their SAML fields.
  Idempotent -- safe to call on every SAML login callback.
  """
  def find_or_create_from_saml(attrs) do
    email = Map.fetch!(attrs, :email)

    case get_user_by_email(email) do
      nil ->
        %User{}
        |> User.saml_changeset(Map.new(attrs))
        |> Repo.insert()

      user ->
        user
        |> User.saml_changeset(Map.new(attrs))
        |> Repo.update()
    end
  end

  @doc """
  Registers a new user with email and password.
  """
  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Authenticates a user by email and password.
  """
  def authenticate_by_email_password(email, password) do
    user = get_user_by_email(email)

    if User.valid_password?(user, password) do
      {:ok, user}
    else
      {:error, :invalid_credentials}
    end
  end

  @doc """
  Gets a user by email.
  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.one(from u in User, where: u.email == ^email)
  end

  @doc """
  Gets a user by ID. Raises if not found.
  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Gets a user by ID. Returns nil if not found.
  """
  def get_user(id), do: Repo.get(User, id)

  @doc """
  Lists all users ordered by email.
  """
  def list_users do
    Repo.all(from u in User, order_by: u.email)
  end

  @doc """
  Searches users by name or email. Returns up to `limit` results.
  Optionally excludes specific user IDs.
  """
  def search_users(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    exclude_ids = Keyword.get(opts, :exclude, [])

    term =
      "%#{query |> String.replace("\\", "\\\\") |> String.replace("%", "\\%") |> String.replace("_", "\\_")}%"

    base =
      User
      |> where([u], ilike(u.email, ^term) or ilike(u.name, ^term))
      |> limit(^limit)
      |> order_by([u], asc: u.email)

    base =
      if exclude_ids == [] do
        base
      else
        where(base, [u], u.id not in ^exclude_ids)
      end

    Repo.all(base)
  end

  @doc """
  Updates a user's role. Prevents demoting the root admin.
  """
  def update_user_role(user_id, role) do
    case Repo.get(User, user_id) do
      nil ->
        {:error, :not_found}

      %User{email: email} when email == @admin_email and role != "admin" ->
        {:error, :cannot_demote_root_admin}

      user ->
        user
        |> User.role_changeset(%{role: role})
        |> Repo.update()
    end
  end

  @doc """
  Changes a user's password. Requires current password verification.
  """
  def change_password(user, current_password, new_password) do
    if User.valid_password?(user, current_password) do
      user
      |> User.password_changeset(%{password: new_password})
      |> Ecto.Changeset.put_change(:force_password_change, false)
      |> Repo.update()
    else
      {:error, :invalid_current_password}
    end
  end

  @doc """
  Sets password for first-time admin setup. No current password required.
  """
  def setup_admin_password(user, password) do
    user
    |> User.password_changeset(%{password: password})
    |> Repo.update()
  end

  @doc """
  Sets a temporary password for a user (admin action). Forces the user
  to change their password on next login.
  """
  def set_temporary_password(user, password) do
    user
    |> User.password_changeset(%{password: password})
    |> Ecto.Changeset.put_change(:force_password_change, true)
    |> Repo.update()
  end

  @doc """
  Updates user preferences by merging new keys into the existing map.
  """
  def update_preferences(user, new_prefs) do
    merged = Map.merge(user.preferences || %{}, new_prefs)

    user
    |> User.preferences_changeset(%{preferences: merged})
    |> Repo.update()
  end

  # --- Invitations ---

  @doc """
  Creates an invitation for the given email, issued by the admin user.
  """
  def create_invitation(email, admin_user_id) do
    %Invitation{}
    |> Invitation.changeset(%{email: email, created_by_id: admin_user_id})
    |> Repo.insert()
  end

  @doc """
  Gets an invitation by its token, preloading the creator.
  """
  def get_invitation_by_token(token) when is_binary(token) do
    Repo.one(from i in Invitation, where: i.token == ^token, preload: [:created_by])
  end

  @doc """
  Lists all invitations ordered by most recent first.
  """
  def list_invitations do
    Repo.all(from i in Invitation, order_by: [desc: i.inserted_at], preload: [:created_by])
  end

  @doc """
  Accepts an invitation: validates token, creates user in a transaction,
  and marks the invitation as used.
  """
  def accept_invitation(token, attrs) do
    Repo.transaction(fn ->
      # Lock the invitation row to prevent concurrent acceptance
      invitation =
        Repo.one(
          from i in Invitation,
            where: i.token == ^token,
            lock: "FOR UPDATE"
        )

      case invitation do
        nil ->
          Repo.rollback(:not_found)

        inv ->
          cond do
            Invitation.used?(inv) ->
              Repo.rollback(:already_used)

            Invitation.expired?(inv) ->
              Repo.rollback(:expired)

            true ->
              user_attrs = %{
                email: inv.email,
                name: attrs[:name] || attrs["name"],
                password: attrs[:password] || attrs["password"]
              }

              case register_user(user_attrs) do
                {:ok, user} ->
                  {1, _} =
                    Repo.update_all(
                      from(i in Invitation,
                        where: i.id == ^inv.id and is_nil(i.used_at)
                      ),
                      set: [
                        used_at: DateTime.utc_now() |> DateTime.truncate(:second)
                      ]
                    )

                  user

                {:error, changeset} ->
                  Repo.rollback(changeset)
              end
          end
      end
    end)
  end

  @doc """
  Revokes (deletes) a pending invitation. Rejects if already used.
  """
  def revoke_invitation(id) do
    case Repo.get(Invitation, id) do
      nil ->
        {:error, :not_found}

      invitation ->
        if Invitation.used?(invitation) do
          {:error, :already_used}
        else
          Repo.delete(invitation)
        end
    end
  end

  # --- Server-side Sessions ---

  @doc """
  Creates a new server-side session for the given user.
  `conn_info` should be a map with optional `:ip_address` and `:user_agent` keys.
  """
  def create_session(user_id, conn_info \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %UserSession{
      user_id: user_id,
      ip_address: conn_info[:ip_address],
      user_agent: conn_info[:user_agent],
      last_active_at: now,
      expires_at: DateTime.add(now, session_max_age(), :second)
    }
    |> Repo.insert()
  end

  @doc """
  Validates a session token and returns `{session, user}` via a single JOIN query.
  Returns `nil` if the session is invalid, expired, or idle-timed-out.
  """
  def validate_session_with_user(token) when is_binary(token) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    idle_cutoff = DateTime.add(now, -session_idle_timeout(), :second)

    Repo.one(
      from s in UserSession,
        join: u in User,
        on: u.id == s.user_id,
        where: s.id == ^token,
        where: s.expires_at > ^now,
        where: s.last_active_at > ^idle_cutoff,
        select: {s, u}
    )
  end

  def validate_session_with_user(_), do: nil

  @doc """
  Updates `last_active_at` on a session. Throttled by the caller (skip if < 60s).
  """
  def touch_session(%UserSession{id: id}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(s in UserSession, where: s.id == ^id)
    |> Repo.update_all(set: [last_active_at: now])
  end

  @doc """
  Deletes a single session by ID.
  """
  def delete_session(session_id) when is_binary(session_id) do
    from(s in UserSession, where: s.id == ^session_id)
    |> Repo.delete_all()
  end

  @doc """
  Atomically deletes a session and returns it. Used by logout to avoid
  TOCTOU race between validate and delete.
  Returns `{:ok, session}` if found and deleted, `:error` otherwise.
  """
  def delete_and_return_session(session_id) when is_binary(session_id) do
    case Repo.delete_all(from(s in UserSession, where: s.id == ^session_id, select: s)) do
      {1, [session]} -> {:ok, session}
      _ -> :error
    end
  end

  @doc """
  Deletes all sessions for a given user.
  """
  def delete_user_sessions(user_id) when is_binary(user_id) do
    from(s in UserSession, where: s.user_id == ^user_id)
    |> Repo.delete_all()
  end

  @doc """
  Deletes all expired sessions (absolute expiration or idle timeout).
  Called by SessionSweeper.
  """
  def delete_expired_sessions do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    idle_cutoff = DateTime.add(now, -session_idle_timeout(), :second)

    from(s in UserSession,
      where: s.expires_at <= ^now or s.last_active_at <= ^idle_cutoff
    )
    |> Repo.delete_all()
  end

  # --- Auth Events ---

  @doc """
  Logs an authentication event. Accepts a map with required `:event_type`
  and optional `:user_id`, `:ip_address`, `:user_agent`, `:metadata`.
  """
  def log_auth_event(%{event_type: event_type} = attrs) do
    %AuthEvent{
      user_id: attrs[:user_id],
      event_type: event_type,
      ip_address: attrs[:ip_address],
      user_agent: attrs[:user_agent],
      metadata: attrs[:metadata] || %{}
    }
    |> Repo.insert()
  end

  @doc """
  Lists auth events for a user, ordered by most recent first.
  Accepts optional `:limit` (default 50).
  """
  def list_auth_events(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(e in AuthEvent,
      where: e.user_id == ^user_id,
      order_by: [desc: e.inserted_at, desc: e.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  # --- Session config helpers ---

  defp session_max_age do
    Application.get_env(:liteskill, :session_max_age_seconds, 86_400)
  end

  defp session_idle_timeout do
    Application.get_env(:liteskill, :session_idle_timeout_seconds, 86_400)
  end
end
