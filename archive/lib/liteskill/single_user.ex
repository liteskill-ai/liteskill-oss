defmodule Liteskill.SingleUser do
  @moduledoc """
  Single-user mode helpers.

  When `SINGLE_USER_MODE=true` the app auto-authenticates as the admin user,
  skips the setup wizard, and collapses Admin + Profile into a unified Settings page.
  """

  alias Liteskill.Accounts
  alias Liteskill.Accounts.User
  alias Liteskill.LlmModels
  alias Liteskill.LlmProviders
  alias Liteskill.Settings

  @doc "Returns true when single-user mode is enabled via config."
  def enabled? do
    Application.get_env(:liteskill, :single_user_mode, false)
  end

  @doc """
  Returns true when single-user mode is enabled AND setup has not been dismissed
  AND any of: no providers, no models, or no embedding model selected.
  """
  def setup_needed? do
    enabled?() and
      not Settings.setup_dismissed?() and
      (LlmProviders.list_all_providers() == [] or
         LlmModels.list_all_models() == [] or
         not Settings.embedding_enabled?())
  end

  @doc "Returns the admin user, or nil if not yet provisioned."
  def auto_user do
    Accounts.get_user_by_email(User.admin_email())
  end

  @doc """
  Ensures the admin account has a password set so `User.setup_required?/1`
  returns false. Called once at boot when single-user mode is active.
  """
  def auto_provision_admin do
    case auto_user() do
      %User{} = admin ->
        if User.setup_required?(admin) do
          password = random_password()
          Accounts.setup_admin_password(admin, password)
        else
          {:ok, admin}
        end

      nil ->
        :noop
    end
  end

  defp random_password do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
