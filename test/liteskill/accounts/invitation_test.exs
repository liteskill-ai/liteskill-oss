defmodule Liteskill.Accounts.InvitationTest do
  use ExUnit.Case, async: true

  alias Liteskill.Accounts.Invitation

  describe "changeset/2" do
    test "generates token and expires_at" do
      changeset = Invitation.changeset(%Invitation{}, %{email: "test@example.com"})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :token) != nil
      assert Ecto.Changeset.get_change(changeset, :expires_at) != nil
    end

    test "downcases email" do
      changeset = Invitation.changeset(%Invitation{}, %{email: "Test@EXAMPLE.com"})

      assert Ecto.Changeset.get_change(changeset, :email) == "test@example.com"
    end

    test "validates email is required" do
      changeset = Invitation.changeset(%Invitation{}, %{})

      refute changeset.valid?
      assert {"can't be blank", _} = changeset.errors[:email]
    end

    test "validates email format" do
      changeset = Invitation.changeset(%Invitation{}, %{email: "notanemail"})

      refute changeset.valid?
      assert {"has invalid format", _} = changeset.errors[:email]
    end

    test "generates URL-safe base64 token" do
      changeset = Invitation.changeset(%Invitation{}, %{email: "test@example.com"})
      token = Ecto.Changeset.get_change(changeset, :token)

      assert is_binary(token)
      assert String.length(token) > 20
      # URL-safe base64 should decode without error
      assert {:ok, _} = Base.url_decode64(token, padding: false)
    end

    test "sets expires_at to ~7 days from now" do
      changeset = Invitation.changeset(%Invitation{}, %{email: "test@example.com"})
      expires_at = Ecto.Changeset.get_change(changeset, :expires_at)

      now = DateTime.utc_now()
      diff = DateTime.diff(expires_at, now, :second)

      # Should be approximately 7 days (604800 seconds), allow ±60s tolerance
      assert diff > 604_700
      assert diff < 604_900
    end

    test "preserves pre-existing token change" do
      pre = Ecto.Changeset.change(%Invitation{}, %{token: "pre-set-token"})
      changeset = Invitation.changeset(pre, %{email: "test@example.com"})

      assert Ecto.Changeset.get_change(changeset, :token) == "pre-set-token"
    end

    test "preserves pre-existing expires_at change" do
      future = ~U[2030-01-01 00:00:00Z]
      pre = Ecto.Changeset.change(%Invitation{}, %{expires_at: future})
      changeset = Invitation.changeset(pre, %{email: "test@example.com"})

      assert Ecto.Changeset.get_change(changeset, :expires_at) == future
    end
  end

  describe "expired?/1" do
    test "returns false for future expiry" do
      expires = DateTime.utc_now() |> DateTime.add(3600)
      refute Invitation.expired?(%Invitation{expires_at: expires})
    end

    test "returns true for past expiry" do
      expires = DateTime.utc_now() |> DateTime.add(-3600)
      assert Invitation.expired?(%Invitation{expires_at: expires})
    end
  end

  describe "used?/1" do
    test "returns false when used_at is nil" do
      refute Invitation.used?(%Invitation{used_at: nil})
    end

    test "returns true when used_at is set" do
      assert Invitation.used?(%Invitation{used_at: DateTime.utc_now()})
    end
  end
end
