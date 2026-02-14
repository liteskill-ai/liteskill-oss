defmodule LiteskillWeb.Router do
  use LiteskillWeb, :router

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
    plug LiteskillWeb.Plugs.Auth, :fetch_current_user
    plug LiteskillWeb.Plugs.RateLimiter, limit: 1000, window_ms: 60_000
  end

  pipeline :require_auth do
    plug LiteskillWeb.Plugs.Auth, :require_authenticated_user
  end

  # Session bridge for LiveView auth
  scope "/auth", LiteskillWeb do
    pipe_through [:browser]

    get "/session", SessionController, :create
    delete "/logout", SessionController, :delete
  end

  # Public LiveView routes
  scope "/", LiteskillWeb do
    pipe_through [:browser]

    live_session :auth,
      on_mount: [{LiteskillWeb.Plugs.LiveAuth, :redirect_if_authenticated}] do
      live "/login", AuthLive, :login
      live "/register", AuthLive, :register
      live "/invite/:token", AuthLive, :invite
    end
  end

  # First-time admin setup
  scope "/", LiteskillWeb do
    pipe_through [:browser]

    live_session :setup,
      on_mount: [{LiteskillWeb.Plugs.LiveAuth, :require_setup_needed}] do
      live "/setup", SetupLive
    end
  end

  # Authenticated LiveView routes
  scope "/", LiteskillWeb do
    pipe_through [:browser]

    live_session :chat,
      on_mount: [{LiteskillWeb.Plugs.LiveAuth, :require_authenticated}] do
      live "/", ChatLive, :index
      live "/conversations", ChatLive, :conversations
      live "/c/:conversation_id", ChatLive, :show
      live "/profile", ChatLive, :info
      live "/profile/password", ChatLive, :password
      live "/profile/admin/servers", ChatLive, :admin_servers
      live "/profile/admin/users", ChatLive, :admin_users
      live "/profile/admin/groups", ChatLive, :admin_groups
      live "/profile/admin/providers", ChatLive, :admin_providers
      live "/profile/admin/models", ChatLive, :admin_models
      live "/wiki", ChatLive, :wiki
      live "/wiki/:document_id", ChatLive, :wiki_page_show
      live "/sources", ChatLive, :sources
      live "/sources/pipeline", ChatLive, :pipeline
      live "/sources/:source_id", ChatLive, :source_show
      live "/sources/:source_id/:document_id", ChatLive, :source_document_show
      live "/mcp", ChatLive, :mcp_servers
      live "/reports", ChatLive, :reports
      live "/reports/:report_id", ChatLive, :report_show
      live "/agents", ChatLive, :agents
      live "/agents/new", ChatLive, :agent_new
      live "/agents/:agent_id", ChatLive, :agent_show
      live "/agents/:agent_id/edit", ChatLive, :agent_edit
      live "/teams", ChatLive, :teams
      live "/teams/new", ChatLive, :team_new
      live "/teams/:team_id", ChatLive, :team_show
      live "/teams/:team_id/edit", ChatLive, :team_edit
      live "/instances", ChatLive, :instances
      live "/instances/new", ChatLive, :instance_new
      live "/instances/:instance_id", ChatLive, :instance_show
      live "/schedules", ChatLive, :schedules
      live "/schedules/new", ChatLive, :schedule_new
      live "/schedules/:schedule_id", ChatLive, :schedule_show
    end
  end

  # Password auth API routes (no auth required)
  scope "/auth", LiteskillWeb do
    pipe_through [:api]

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
