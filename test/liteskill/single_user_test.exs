defmodule Liteskill.SingleUserTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Accounts
  alias Liteskill.Accounts.User
  alias Liteskill.LlmModels
  alias Liteskill.LlmProviders
  alias Liteskill.Settings
  alias Liteskill.SingleUser

  describe "enabled?/0" do
    test "returns false by default" do
      refute SingleUser.enabled?()
    end

    test "returns true when configured" do
      original = Application.get_env(:liteskill, :single_user_mode, false)
      Application.put_env(:liteskill, :single_user_mode, true)

      on_exit(fn ->
        Application.put_env(:liteskill, :single_user_mode, original)
      end)

      assert SingleUser.enabled?()
    end
  end

  describe "auto_user/0" do
    test "returns admin user when it exists" do
      Accounts.ensure_admin_user()
      user = SingleUser.auto_user()
      assert %User{} = user
      assert user.email == User.admin_email()
    end
  end

  describe "auto_provision_admin/0" do
    test "sets password on admin when setup is required" do
      admin = Accounts.ensure_admin_user()
      assert User.setup_required?(admin)

      assert {:ok, updated} = SingleUser.auto_provision_admin()
      refute User.setup_required?(updated)
      assert updated.password_hash
    end

    test "returns :noop when admin user does not exist" do
      # Delete the admin user so auto_user() returns nil
      admin_email = User.admin_email()

      case Liteskill.Repo.get_by(User, email: admin_email) do
        nil -> :ok
        user -> Liteskill.Repo.delete!(user)
      end

      assert :noop = SingleUser.auto_provision_admin()
    end

    test "is a no-op when admin already has a password" do
      admin = Accounts.ensure_admin_user()
      {:ok, admin} = Accounts.setup_admin_password(admin, "a_secure_password1")
      refute User.setup_required?(admin)

      assert {:ok, same} = SingleUser.auto_provision_admin()
      assert same.id == admin.id
    end
  end

  describe "setup_needed?/0" do
    setup do
      original = Application.get_env(:liteskill, :single_user_mode, false)

      on_exit(fn ->
        Application.put_env(:liteskill, :single_user_mode, original)
      end)

      admin = Accounts.ensure_admin_user()
      {:ok, admin: admin}
    end

    test "returns false when single_user_mode is disabled", %{admin: _admin} do
      Application.put_env(:liteskill, :single_user_mode, false)
      refute SingleUser.setup_needed?()
    end

    test "returns true when enabled and no providers exist", %{admin: _admin} do
      Application.put_env(:liteskill, :single_user_mode, true)
      assert SingleUser.setup_needed?()
    end

    test "returns true when enabled and providers exist but no models", %{admin: admin} do
      Application.put_env(:liteskill, :single_user_mode, true)

      {:ok, _provider} =
        LlmProviders.create_provider(%{
          name: "Test Provider",
          provider_type: "anthropic",
          provider_config: %{},
          user_id: admin.id
        })

      assert SingleUser.setup_needed?()
    end

    test "returns true when enabled and no embedding model selected", %{admin: admin} do
      Application.put_env(:liteskill, :single_user_mode, true)

      {:ok, provider} =
        LlmProviders.create_provider(%{
          name: "Test Provider",
          provider_type: "anthropic",
          provider_config: %{},
          user_id: admin.id
        })

      {:ok, _model} =
        LlmModels.create_model(%{
          name: "Test Model",
          model_id: "claude-3-5-sonnet-20241022",
          provider_id: provider.id,
          user_id: admin.id,
          instance_wide: true
        })

      # No embedding model selected yet
      assert SingleUser.setup_needed?()
    end

    test "returns false when all three configured", %{admin: admin} do
      Application.put_env(:liteskill, :single_user_mode, true)

      {:ok, provider} =
        LlmProviders.create_provider(%{
          name: "Test Provider",
          provider_type: "anthropic",
          provider_config: %{},
          user_id: admin.id
        })

      {:ok, _model} =
        LlmModels.create_model(%{
          name: "Test Model",
          model_id: "claude-3-5-sonnet-20241022",
          provider_id: provider.id,
          user_id: admin.id,
          instance_wide: true
        })

      {:ok, embed_model} =
        LlmModels.create_model(%{
          name: "Embedding Model",
          model_id: "amazon.titan-embed-text-v2:0",
          model_type: "embedding",
          provider_id: provider.id,
          user_id: admin.id,
          instance_wide: true
        })

      {:ok, _settings} = Settings.update_embedding_model(embed_model.id)

      refute SingleUser.setup_needed?()

      # Verify the individual conditions
      assert LlmProviders.list_all_providers() != []
      assert LlmModels.list_all_models() != []
      assert Settings.embedding_enabled?()
    end

    test "returns false when setup has been dismissed", %{admin: _admin} do
      Application.put_env(:liteskill, :single_user_mode, true)

      # No providers/models/embedding, but setup was dismissed
      assert LlmProviders.list_all_providers() == []
      {:ok, _} = Settings.dismiss_setup()

      refute SingleUser.setup_needed?()
    end
  end
end
