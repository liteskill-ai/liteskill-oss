defmodule LiteskillWeb.Router do
  @moduledoc false
  use LiteskillWeb, :router

  alias LiteskillWeb.Plugs.Auth
  alias LiteskillWeb.Plugs.LiveAuth
  alias LiteskillWeb.Plugs.RateLimiter

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LiteskillWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug Auth, :fetch_current_user
    plug RateLimiter, limit: 1000, window_ms: 60_000
  end

  pipeline :require_auth do
    plug Auth, :require_authenticated_user
  end

  pipeline :auth_rate_limit do
    plug RateLimiter, limit: 60, window_ms: 60_000
  end

  # SAML SSO routes (Samly handles auth flow)
  # coveralls-ignore-start - requires SAML IdP configuration
  scope "/sso" do
    forward "/", Samly.Router
  end

  # SAML post-auth callback
  scope "/auth", LiteskillWeb do
    pipe_through [:browser]

    get "/saml/callback", SamlAuthController, :callback
  end

  # coveralls-ignore-stop

  # Session bridge for LiveView auth
  scope "/auth", LiteskillWeb do
    pipe_through [:browser]

    get "/session", SessionController, :create
    delete "/logout", SessionController, :delete

    # OpenRouter OAuth PKCE flow (must be above OIDC wildcard routes)
    get "/openrouter", OpenRouterController, :start
    get "/openrouter/callback", OpenRouterController, :callback
  end

  # Public LiveView routes (rate-limited to prevent brute force)
  scope "/", LiteskillWeb do
    pipe_through [:browser, :auth_rate_limit]

    live_session :auth,
      on_mount: [{LiveAuth, :redirect_if_authenticated}] do
      live "/login", AuthLive, :login
      live "/register", AuthLive, :register
      live "/invite/:token", AuthLive, :invite
    end
  end

  # First-time admin setup
  scope "/", LiteskillWeb do
    pipe_through [:browser]

    live_session :setup,
      on_mount: [{LiveAuth, :require_setup_needed}] do
      live "/setup", SetupLive
    end
  end

  # Admin LiveView routes (require admin role)
  scope "/", LiteskillWeb do
    pipe_through [:browser]

    live_session :admin,
      on_mount: [{LiveAuth, :require_admin}] do
      live "/admin", AdminLive, :admin_usage
      live "/admin/usage", AdminLive, :admin_usage
      live "/admin/servers", AdminLive, :admin_servers
      live "/admin/users", AdminLive, :admin_users
      live "/admin/groups", AdminLive, :admin_groups
      live "/admin/providers", AdminLive, :admin_providers
      live "/admin/models", AdminLive, :admin_models
      live "/admin/roles", AdminLive, :admin_roles
      live "/admin/rag", AdminLive, :admin_rag
      live "/admin/setup", SetupLive, :admin_setup
      # Settings routes (single-user mode unified settings page)
      live "/settings", AdminLive, :settings_usage
      live "/settings/general", AdminLive, :settings_general
      live "/settings/providers", AdminLive, :settings_providers
      live "/settings/models", AdminLive, :settings_models
      live "/settings/rag", AdminLive, :settings_rag
      live "/settings/account", AdminLive, :settings_account
    end
  end

  # Wiki file operations (authenticated browser routes)
  scope "/wiki", LiteskillWeb do
    pipe_through [:browser]

    get "/:space_id/export", WikiExportController, :export
  end

  # Authenticated LiveView routes
  scope "/", LiteskillWeb do
    pipe_through [:browser]

    live_session :chat,
      on_mount: [{LiveAuth, :require_authenticated}] do
      live "/", ChatLive, :index
      live "/conversations", ChatLive, :conversations
      live "/c/:conversation_id", ChatLive, :show
      live "/profile", ProfileLive, :info
      live "/profile/password", ProfileLive, :password
      live "/profile/providers", ProfileLive, :user_providers
      live "/profile/models", ProfileLive, :user_models
      live "/wiki", WikiLive, :wiki
      live "/wiki/:document_id", WikiLive, :wiki_page_show
      live "/sources", SourcesLive, :sources
      live "/sources/pipeline", PipelineLive, :pipeline
      live "/sources/:source_id", SourcesLive, :source_show
      live "/sources/:source_id/:document_id", SourcesLive, :source_document_show
      live "/mcp", McpLive, :mcp_servers
      live "/reports", ReportsLive, :reports
      live "/reports/:report_id", ReportsLive, :report_show
      live "/agents", AgentStudioLive, :agent_studio
      live "/agents/list", AgentStudioLive, :agents
      live "/agents/new", AgentStudioLive, :agent_new
      live "/agents/:agent_id", AgentStudioLive, :agent_show
      live "/agents/:agent_id/edit", AgentStudioLive, :agent_edit
      live "/teams", AgentStudioLive, :teams
      live "/teams/new", AgentStudioLive, :team_new
      live "/teams/:team_id", AgentStudioLive, :team_show
      live "/teams/:team_id/edit", AgentStudioLive, :team_edit
      live "/runs", AgentStudioLive, :runs
      live "/runs/new", AgentStudioLive, :run_new
      live "/runs/:run_id", AgentStudioLive, :run_show
      live "/runs/:run_id/logs/:log_id", AgentStudioLive, :run_log_show
      live "/schedules", AgentStudioLive, :schedules
      live "/schedules/new", AgentStudioLive, :schedule_new
      live "/schedules/:schedule_id", AgentStudioLive, :schedule_show
    end
  end

  # Password auth API routes (no auth required, strict rate limit)
  scope "/auth", LiteskillWeb do
    pipe_through [:api, :auth_rate_limit]

    post "/register", PasswordAuthController, :register
    post "/login", PasswordAuthController, :login
  end

  # OIDC auth routes
  scope "/auth", LiteskillWeb do
    pipe_through [:browser]

    # coveralls-ignore-start - Ueberauth provider redirect, requires OIDC configuration
    get "/:provider", AuthController, :request
    get "/:provider/callback", AuthController, :callback
    # coveralls-ignore-stop
    post "/:provider/callback", AuthController, :callback
  end

  # API routes
  scope "/api", LiteskillWeb do
    pipe_through [:api, :require_auth]

    resources "/conversations", ConversationController, only: [:index, :create, :show] do
      post "/messages", ConversationController, :send_message
      post "/fork", ConversationController, :fork
      post "/acls", ConversationController, :grant_access
      delete "/acls/:target_user_id", ConversationController, :revoke_access
      delete "/membership", ConversationController, :leave
    end

    resources "/groups", GroupController, only: [:index, :create, :show, :delete] do
      post "/members", GroupController, :add_member
      delete "/members/:user_id", GroupController, :remove_member
    end
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:liteskill, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: LiteskillWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
