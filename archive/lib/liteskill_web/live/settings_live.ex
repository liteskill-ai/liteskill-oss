defmodule LiteskillWeb.SettingsLive do
  @moduledoc """
  Thin helper module for single-user "Settings" mode.

  Maps `:settings_*` action atoms to their admin/profile counterparts and
  provides a filtered tab bar component shared by AdminLive and ProfileLive
  when rendered inside the settings context.
  """

  use LiteskillWeb, :html

  @settings_actions [
    :settings_usage,
    :settings_general,
    :settings_providers,
    :settings_models,
    :settings_rag,
    :settings_account
  ]

  @doc "Returns true when the given action is a settings action."
  def settings_action?(action), do: action in @settings_actions

  @doc "Maps a settings action to the corresponding admin action atom."
  def settings_to_admin_action(:settings_usage), do: :admin_usage
  def settings_to_admin_action(:settings_general), do: :admin_servers
  def settings_to_admin_action(:settings_providers), do: :admin_providers
  def settings_to_admin_action(:settings_models), do: :admin_models
  def settings_to_admin_action(:settings_rag), do: :admin_rag
  def settings_to_admin_action(_), do: nil

  attr :active, :atom, required: true

  def settings_tab_bar(assigns) do
    ~H"""
    <div class="flex gap-1 overflow-x-auto" role="tablist">
      <.tab_link label="Usage" to={~p"/settings"} active={@active == :settings_usage} />
      <.tab_link label="General" to={~p"/settings/general"} active={@active == :settings_general} />
      <.tab_link
        label="Providers"
        to={~p"/settings/providers"}
        active={@active == :settings_providers}
      />
      <.tab_link label="Models" to={~p"/settings/models"} active={@active == :settings_models} />
      <.tab_link label="RAG" to={~p"/settings/rag"} active={@active == :settings_rag} />
      <.tab_link label="Account" to={~p"/settings/account"} active={@active == :settings_account} />
    </div>
    """
  end

  defp tab_link(assigns) do
    ~H"""
    <.link
      navigate={@to}
      class={[
        "tab tab-bordered whitespace-nowrap",
        @active && "tab-active"
      ]}
    >
      {@label}
    </.link>
    """
  end
end
