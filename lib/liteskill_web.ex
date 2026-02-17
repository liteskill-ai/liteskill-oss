defmodule LiteskillWeb do
  use Boundary,
    deps: [
      Liteskill.Accounts,
      Liteskill.Agents,
      Liteskill.Aggregate,
      Liteskill.Authorization,
      Liteskill.BuiltinSources,
      Liteskill.BuiltinTools,
      Liteskill.Chat,
      Liteskill.Crypto,
      Liteskill.DataSources,
      Liteskill.EventStore,
      Liteskill.Groups,
      Liteskill.LLM,
      Liteskill.LlmModels,
      Liteskill.LlmProviders,
      Liteskill.McpServers,
      Liteskill.Rag,
      Liteskill.Rbac,
      Liteskill.Reports,
      Liteskill.Runs,
      Liteskill.Schedules,
      Liteskill.Settings,
      Liteskill.Teams,
      Liteskill.Usage
    ],
    exports: []

  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use LiteskillWeb, :controller
      use LiteskillWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: LiteskillWeb.Gettext

      import Plug.Conn
      import LiteskillWeb.ErrorHelpers

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView
      import LiteskillWeb.ErrorHelpers

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      import LiteskillWeb.ErrorHelpers

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # Translation
      use Gettext, backend: LiteskillWeb.Gettext

      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      import LiteskillWeb.CoreComponents

      # Common modules used in templates
      alias Phoenix.LiveView.JS
      alias LiteskillWeb.Layouts

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: LiteskillWeb.Endpoint,
        router: LiteskillWeb.Router,
        statics: LiteskillWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
