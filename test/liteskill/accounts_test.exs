defmodule Liteskill.AccountsTest do
  use Liteskill.DataCase, async: true

  alias Liteskill.Accounts
  alias Liteskill.Accounts.User

  @valid_attrs %{
    email: "test@example.com",
    name: "Test User",
    oidc_sub: "sub-123",
    oidc_issuer: "https://idp.example.com"
  }

  describe "find_or_create_from_oidc/1" do
    test "creates a new user when none exists" do
      attrs = unique_oidc_attrs()
      assert {:ok, %User{} = user} = Accounts.find_or_create_from_oidc(attrs)

      assert user.oidc_sub == attrs.oidc_sub
      assert user.name == "Test User"
      assert user.id != nil
    end

    test "returns existing user on duplicate oidc_sub + oidc_issuer" do
      attrs = unique_oidc_attrs()
      {:ok, user1} = Accounts.find_or_create_from_oidc(attrs)
      {:ok, user2} = Accounts.find_or_create_from_oidc(attrs)

      assert user1.id == user2.id
    end

    test "creates separate users for different subjects" do
      {:ok, user1} = Accounts.find_or_create_from_oidc(unique_oidc_attrs())

      {:ok, user2} =
        Accounts.find_or_create_from_oidc(unique_oidc_attrs(%{oidc_sub: "sub-different"}))

      assert user1.id != user2.id
    end

    test "returns error for missing required fields" do
      assert {:error, %Ecto.Changeset{}} =
               Accounts.find_or_create_from_oidc(%{oidc_sub: "x", oidc_issuer: "y"})
    end
  end

  describe "get_user!/1" do
    test "returns user by id" do
      {:ok, user} = Accounts.find_or_create_from_oidc(unique_oidc_attrs())
      assert Accounts.get_user!(user.id).id == user.id
    end

    test "raises for unknown id" do
      assert_raise Ecto.NoResultsError, fn ->
        Accounts.get_user!(Ecto.UUID.generate())
      end
    end
  end

  describe "register_user/1" do
    test "creates a user with email and password" do
      attrs = %{email: unique_email(), name: "Password User", password: "supersecretpass123"}
      assert {:ok, %User{} = user} = Accounts.register_user(attrs)

      assert user.email == attrs.email
      assert user.name == "Password User"
      assert user.password_hash != nil
      assert user.password == nil
    end

    test "returns error for short password" do
      attrs = %{email: unique_email(), password: "short"}
      assert {:error, changeset} = Accounts.register_user(attrs)
      assert "should be at least 12 character(s)" in errors_on(changeset).password
    end

    test "returns error for too-long password" do
      attrs = %{email: unique_email(), password: String.duplicate("a", 73)}
      assert {:error, changeset} = Accounts.register_user(attrs)
      assert "should be at most 72 character(s)" in errors_on(changeset).password
    end

    test "returns error for duplicate email" do
      email = unique_email()
      {:ok, _} = Accounts.register_user(%{email: email, password: "supersecretpass123"})

      assert {:error, changeset} =
               Accounts.register_user(%{email: email, password: "supersecretpass123"})

      assert "has already been taken" in errors_on(changeset).email
    end

    test "returns error for missing email" do
      assert {:error, changeset} = Accounts.register_user(%{password: "supersecretpass123"})
      assert "can't be blank" in errors_on(changeset).email
    end
  end

  describe "authenticate_by_email_password/2" do
    test "returns user for valid credentials" do
      email = unique_email()
      {:ok, user} = Accounts.register_user(%{email: email, password: "supersecretpass123"})

      assert {:ok, authed} = Accounts.authenticate_by_email_password(email, "supersecretpass123")
      assert authed.id == user.id
    end

    test "returns error for wrong password" do
      email = unique_email()
      {:ok, _} = Accounts.register_user(%{email: email, password: "supersecretpass123"})

      assert {:error, :invalid_credentials} =
               Accounts.authenticate_by_email_password(email, "wrongpassword12")
    end

    test "returns error for nonexistent email" do
      assert {:error, :invalid_credentials} =
               Accounts.authenticate_by_email_password("nobody@example.com", "doesntmatter1")
    end
  end

  describe "get_user_by_email/1" do
    test "returns user by email" do
      email = unique_email()
      {:ok, user} = Accounts.register_user(%{email: email, password: "supersecretpass123"})

      found = Accounts.get_user_by_email(email)
      assert found.id == user.id
    end

    test "returns nil for unknown email" do
      assert Accounts.get_user_by_email("nobody@example.com") == nil
    end
  end

  describe "ensure_admin_user/0" do
    test "creates admin user when none exists" do
      # Delete admin if it exists from app boot
      admin = Accounts.get_user_by_email("admin@liteskill.local")
      if admin, do: Repo.delete!(admin)

      user = Accounts.ensure_admin_user()

      assert user.email == "admin@liteskill.local"
      assert user.name == "Admin"
      assert user.role == "admin"
    end

    test "is idempotent — returns existing admin" do
      user1 = Accounts.ensure_admin_user()
      user2 = Accounts.ensure_admin_user()

      assert user1.id == user2.id
    end

    test "forces role back to admin if changed" do
      user = Accounts.ensure_admin_user()
      user |> User.role_changeset(%{role: "user"}) |> Repo.update!()

      restored = Accounts.ensure_admin_user()
      assert restored.id == user.id
      assert restored.role == "admin"
    end
  end

  describe "list_users/0" do
    test "returns all users ordered by email" do
      {:ok, _b} = Accounts.register_user(%{email: "b@test.com", password: "supersecretpass123"})
      {:ok, _a} = Accounts.register_user(%{email: "a@test.com", password: "supersecretpass123"})

      users = Accounts.list_users()
      emails = Enum.map(users, & &1.email)

      assert "a@test.com" in emails
      assert "b@test.com" in emails
      # Verify ordering
      a_idx = Enum.find_index(emails, &(&1 == "a@test.com"))
      b_idx = Enum.find_index(emails, &(&1 == "b@test.com"))
      assert a_idx < b_idx
    end
  end

  describe "update_user_role/2" do
    test "changes user role" do
      {:ok, user} =
        Accounts.register_user(%{email: unique_email(), password: "supersecretpass123"})

      assert {:ok, updated} = Accounts.update_user_role(user.id, "admin")
      assert updated.role == "admin"
    end

    test "prevents demoting root admin" do
      admin = Accounts.ensure_admin_user()

      assert {:error, :cannot_demote_root_admin} = Accounts.update_user_role(admin.id, "user")
    end

    test "returns not_found for unknown user" do
      assert {:error, :not_found} = Accounts.update_user_role(Ecto.UUID.generate(), "admin")
    end

    test "rejects invalid role" do
      {:ok, user} =
        Accounts.register_user(%{email: unique_email(), password: "supersecretpass123"})

      assert {:error, changeset} = Accounts.update_user_role(user.id, "superadmin")
      assert "is invalid" in errors_on(changeset).role
    end
  end

  describe "change_password/3" do
    test "changes password with valid current password" do
      {:ok, user} =
        Accounts.register_user(%{email: unique_email(), password: "supersecretpass123"})

      assert {:ok, updated} =
               Accounts.change_password(user, "supersecretpass123", "newpassword12345")

      assert User.valid_password?(updated, "newpassword12345")
      refute User.valid_password?(updated, "supersecretpass123")
    end

    test "rejects invalid current password" do
      {:ok, user} =
        Accounts.register_user(%{email: unique_email(), password: "supersecretpass123"})

      assert {:error, :invalid_current_password} =
               Accounts.change_password(user, "wrongpassword12", "newpassword12345")
    end

    test "validates new password length" do
      {:ok, user} =
        Accounts.register_user(%{email: unique_email(), password: "supersecretpass123"})

      assert {:error, changeset} = Accounts.change_password(user, "supersecretpass123", "short")
      assert "should be at least 12 character(s)" in errors_on(changeset).password
    end

    test "clears force_password_change flag on success" do
      {:ok, user} =
        Accounts.register_user(%{email: unique_email(), password: "supersecretpass123"})

      {:ok, forced} = Accounts.set_temporary_password(user, "temporarypass123")
      assert forced.force_password_change == true

      {:ok, updated} =
        Accounts.change_password(forced, "temporarypass123", "newpermanentpass1")

      assert updated.force_password_change == false
    end
  end

  describe "setup_admin_password/2" do
    test "sets password without current password" do
      admin = Accounts.ensure_admin_user()

      assert {:ok, updated} = Accounts.setup_admin_password(admin, "adminpassword123")
      assert User.valid_password?(updated, "adminpassword123")
    end

    test "validates password length" do
      admin = Accounts.ensure_admin_user()

      assert {:error, changeset} = Accounts.setup_admin_password(admin, "short")
      assert "should be at least 12 character(s)" in errors_on(changeset).password
    end
  end

  describe "set_temporary_password/2" do
    test "sets password and force_password_change flag" do
      {:ok, user} =
        Accounts.register_user(%{email: unique_email(), password: "supersecretpass123"})

      assert user.force_password_change == false

      assert {:ok, updated} = Accounts.set_temporary_password(user, "temporarypass123")
      assert updated.force_password_change == true
      assert User.valid_password?(updated, "temporarypass123")
    end

    test "user can authenticate with temporary password" do
      email = unique_email()
      {:ok, user} = Accounts.register_user(%{email: email, password: "supersecretpass123"})

      {:ok, _} = Accounts.set_temporary_password(user, "temporarypass123")

      assert {:ok, authed} = Accounts.authenticate_by_email_password(email, "temporarypass123")
      assert authed.force_password_change == true
    end

    test "validates password length" do
      {:ok, user} =
        Accounts.register_user(%{email: unique_email(), password: "supersecretpass123"})

      assert {:error, changeset} = Accounts.set_temporary_password(user, "short")
      assert "should be at least 12 character(s)" in errors_on(changeset).password
    end
  end

  describe "User.force_password_change" do
    test "defaults to false on new users" do
      {:ok, user} =
        Accounts.register_user(%{email: unique_email(), password: "supersecretpass123"})

      assert user.force_password_change == false
    end

    test "defaults to false for OIDC users" do
      {:ok, user} = Accounts.find_or_create_from_oidc(unique_oidc_attrs())
      assert user.force_password_change == false
    end
  end

  describe "User.admin?/1" do
    test "returns true for admin role" do
      assert User.admin?(%User{role: "admin"})
    end

    test "returns false for user role" do
      refute User.admin?(%User{role: "user"})
    end
  end

  describe "User.setup_required?/1" do
    test "returns true for admin with no password" do
      assert User.setup_required?(%User{email: "admin@liteskill.local", password_hash: nil})
    end

    test "returns false for admin with password" do
      refute User.setup_required?(%User{email: "admin@liteskill.local", password_hash: "hash"})
    end

    test "returns false for non-admin email" do
      refute User.setup_required?(%User{email: "user@example.com", password_hash: nil})
    end
  end

  describe "User.accent_color/1" do
    test "returns accent color from preferences" do
      user = %User{preferences: %{"accent_color" => "blue"}}
      assert User.accent_color(user) == "blue"
    end

    test "defaults to purple when no preference set" do
      assert User.accent_color(%User{preferences: %{}}) == "purple"
      assert User.accent_color(%User{}) == "purple"
    end
  end

  describe "User.accent_colors/0" do
    test "returns the list of available accent colors" do
      colors = User.accent_colors()
      assert length(colors) == 11
      assert "orange" in colors
      assert "blue" in colors
      assert "royal-blue" in colors
    end
  end

  describe "User.preferences_changeset/2" do
    test "accepts valid accent color" do
      changeset = User.preferences_changeset(%User{}, %{preferences: %{"accent_color" => "blue"}})
      assert changeset.valid?
    end

    test "rejects invalid accent color" do
      changeset =
        User.preferences_changeset(%User{}, %{preferences: %{"accent_color" => "neon"}})

      refute changeset.valid?
      assert "invalid accent color" in errors_on(changeset).preferences
    end

    test "allows preferences without accent_color" do
      changeset =
        User.preferences_changeset(%User{}, %{preferences: %{"other_pref" => "value"}})

      assert changeset.valid?
    end
  end

  describe "update_preferences/2" do
    test "updates accent color" do
      {:ok, user} =
        Accounts.register_user(%{email: unique_email(), password: "supersecretpass123"})

      assert {:ok, updated} = Accounts.update_preferences(user, %{"accent_color" => "blue"})
      assert updated.preferences["accent_color"] == "blue"
    end

    test "merges preferences without overwriting existing" do
      {:ok, user} =
        Accounts.register_user(%{email: unique_email(), password: "supersecretpass123"})

      {:ok, with_accent} = Accounts.update_preferences(user, %{"accent_color" => "blue"})
      {:ok, with_both} = Accounts.update_preferences(with_accent, %{"other_pref" => "value"})

      assert with_both.preferences["accent_color"] == "blue"
      assert with_both.preferences["other_pref"] == "value"
    end

    test "rejects invalid accent color" do
      {:ok, user} =
        Accounts.register_user(%{email: unique_email(), password: "supersecretpass123"})

      assert {:error, _} = Accounts.update_preferences(user, %{"accent_color" => "neon_green"})
    end
  end

  describe "search_users/2" do
    test "finds users by email" do
      {:ok, user} =
        Accounts.find_or_create_from_oidc(unique_oidc_attrs(%{email: "findme@test.com"}))

      results = Accounts.search_users("findme")
      assert Enum.any?(results, &(&1.id == user.id))
    end

    test "finds users by name" do
      {:ok, user} =
        Accounts.find_or_create_from_oidc(unique_oidc_attrs(%{name: "Findable Person"}))

      results = Accounts.search_users("Findable")
      assert Enum.any?(results, &(&1.id == user.id))
    end

    test "excludes specified user IDs" do
      {:ok, user} =
        Accounts.find_or_create_from_oidc(
          unique_oidc_attrs(%{email: "exclude-me@search.com", name: "ExcludeMe"})
        )

      results = Accounts.search_users("ExcludeMe", exclude: [user.id])
      refute Enum.any?(results, &(&1.id == user.id))
    end

    test "respects limit option" do
      for i <- 1..5 do
        Accounts.find_or_create_from_oidc(
          unique_oidc_attrs(%{email: "lim#{i}@searchlimit.com", name: "LimitSearch #{i}"})
        )
      end

      results = Accounts.search_users("searchlimit", limit: 2)
      assert length(results) <= 2
    end

    test "escapes percent in search term" do
      results = Accounts.search_users("100%match")
      assert is_list(results)
    end
  end

  describe "create_invitation/2" do
    test "creates an invitation for the given email" do
      {:ok, admin} =
        Accounts.register_user(%{email: unique_email(), password: "supersecretpass123"})

      assert {:ok, invitation} = Accounts.create_invitation("invitee@example.com", admin.id)
      assert invitation.email == "invitee@example.com"
      assert invitation.token != nil
      assert invitation.expires_at != nil
      assert invitation.created_by_id == admin.id
    end

    test "downcases email" do
      {:ok, admin} =
        Accounts.register_user(%{email: unique_email(), password: "supersecretpass123"})

      assert {:ok, invitation} = Accounts.create_invitation("UPPER@CASE.com", admin.id)
      assert invitation.email == "upper@case.com"
    end
  end

  describe "get_invitation_by_token/1" do
    test "returns invitation by token with preloaded creator" do
      {:ok, admin} =
        Accounts.register_user(%{email: unique_email(), password: "supersecretpass123"})

      {:ok, invitation} = Accounts.create_invitation("test@inv.com", admin.id)

      found = Accounts.get_invitation_by_token(invitation.token)
      assert found.id == invitation.id
      assert found.created_by.id == admin.id
    end

    test "returns nil for unknown token" do
      assert Accounts.get_invitation_by_token("nonexistent-token") == nil
    end
  end

  describe "list_invitations/0" do
    test "returns all invitations ordered by most recent first" do
      {:ok, admin} =
        Accounts.register_user(%{email: unique_email(), password: "supersecretpass123"})

      {:ok, inv1} = Accounts.create_invitation("first@inv.com", admin.id)
      {:ok, inv2} = Accounts.create_invitation("second@inv.com", admin.id)

      invitations = Accounts.list_invitations()
      ids = Enum.map(invitations, & &1.id)

      assert inv1.id in ids
      assert inv2.id in ids
    end
  end

  describe "accept_invitation/2" do
    test "creates user and marks invitation as used" do
      {:ok, admin} =
        Accounts.register_user(%{email: unique_email(), password: "supersecretpass123"})

      email = unique_email()
      {:ok, invitation} = Accounts.create_invitation(email, admin.id)

      assert {:ok, user} =
               Accounts.accept_invitation(invitation.token, %{
                 name: "New User",
                 password: "supersecretpass123"
               })

      assert user.email == String.downcase(email)
      assert user.name == "New User"

      # Invitation should be marked as used
      updated = Accounts.get_invitation_by_token(invitation.token)
      assert updated.used_at != nil
    end

    test "returns error for unknown token" do
      assert {:error, :not_found} =
               Accounts.accept_invitation("bad-token", %{
                 name: "X",
                 password: "supersecretpass123"
               })
    end

    test "returns error for expired invitation" do
      {:ok, admin} =
        Accounts.register_user(%{email: unique_email(), password: "supersecretpass123"})

      {:ok, invitation} = Accounts.create_invitation(unique_email(), admin.id)

      # Manually expire it
      invitation
      |> Ecto.Changeset.change(%{
        expires_at: DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:second)
      })
      |> Repo.update!()

      assert {:error, :expired} =
               Accounts.accept_invitation(invitation.token, %{
                 name: "X",
                 password: "supersecretpass123"
               })
    end

    test "returns error for already-used invitation" do
      {:ok, admin} =
        Accounts.register_user(%{email: unique_email(), password: "supersecretpass123"})

      {:ok, invitation} = Accounts.create_invitation(unique_email(), admin.id)

      # Use it first
      {:ok, _} =
        Accounts.accept_invitation(invitation.token, %{
          name: "First",
          password: "supersecretpass123"
        })

      # Try again
      assert {:error, :already_used} =
               Accounts.accept_invitation(invitation.token, %{
                 name: "Second",
                 password: "supersecretpass123"
               })
    end

    test "rolls back on user validation error" do
      {:ok, admin} =
        Accounts.register_user(%{email: unique_email(), password: "supersecretpass123"})

      {:ok, invitation} = Accounts.create_invitation(unique_email(), admin.id)

      # Short password should fail
      assert {:error, %Ecto.Changeset{}} =
               Accounts.accept_invitation(invitation.token, %{name: "X", password: "short"})

      # Invitation should NOT be marked as used
      inv = Accounts.get_invitation_by_token(invitation.token)
      assert inv.used_at == nil
    end
  end

  describe "revoke_invitation/1" do
    test "deletes a pending invitation" do
      {:ok, admin} =
        Accounts.register_user(%{email: unique_email(), password: "supersecretpass123"})

      {:ok, invitation} = Accounts.create_invitation(unique_email(), admin.id)

      assert {:ok, _} = Accounts.revoke_invitation(invitation.id)
      assert Accounts.get_invitation_by_token(invitation.token) == nil
    end

    test "returns error for already-used invitation" do
      {:ok, admin} =
        Accounts.register_user(%{email: unique_email(), password: "supersecretpass123"})

      {:ok, invitation} = Accounts.create_invitation(unique_email(), admin.id)

      {:ok, _} =
        Accounts.accept_invitation(invitation.token, %{
          name: "User",
          password: "supersecretpass123"
        })

      assert {:error, :already_used} = Accounts.revoke_invitation(invitation.id)
    end

    test "returns error for not found" do
      assert {:error, :not_found} = Accounts.revoke_invitation(Ecto.UUID.generate())
    end
  end

  defp unique_oidc_attrs(overrides \\ %{}) do
    unique = System.unique_integer([:positive])

    Map.merge(
      %{@valid_attrs | email: "test-#{unique}@example.com", oidc_sub: "sub-#{unique}"},
      overrides
    )
  end

  defp unique_email do
    "test-#{System.unique_integer([:positive])}@example.com"
  end
end
