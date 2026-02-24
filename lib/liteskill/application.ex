defmodule Liteskill.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Liteskill.Crypto.validate_key!()
    LiteskillWeb.Plugs.RateLimiter.create_table()
    Liteskill.LlmGateway.TokenBucket.create_table()

    children =
      [
        LiteskillWeb.Telemetry,
        # Desktop: start bundled PostgreSQL before Repo
        if(desktop_mode?(), do: Liteskill.Desktop.PostgresManager),
        Liteskill.Repo,
        {DNSCluster, query: Application.get_env(:liteskill, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Liteskill.PubSub},
        # coveralls-ignore-next-line
        unless(test_env?(), do: Liteskill.Rag.EmbedQueue),
        {Oban, Application.fetch_env!(:liteskill, Oban)},
        # Ensure root admin account exists on boot (skip in test — sandbox not available)
        # coveralls-ignore-start
        unless(test_env?(),
          do:
            {Task,
             fn ->
               Liteskill.Accounts.ensure_admin_user()
               Liteskill.Rbac.ensure_system_roles()
               Liteskill.LlmProviders.ensure_env_providers()
               Liteskill.Settings.get()

               if Liteskill.SingleUser.enabled?(),
                 do: Liteskill.SingleUser.auto_provision_admin()
             end}
        ),
        # coveralls-ignore-stop
        # OpenRouter OAuth PKCE state store (desktop mode cross-browser flow)
        Liteskill.OpenRouter.StateStore,
        # Periodic sweep of stale rate limiter ETS buckets
        LiteskillWeb.Plugs.RateLimiter.Sweeper,
        # Task supervisor for LLM streaming and other async work
        {Task.Supervisor, name: Liteskill.TaskSupervisor},
        # Stream registry — monitors active LLM stream tasks, triggers recovery on crash
        Liteskill.Chat.StreamRegistry,
        # LLM Gateway: per-provider circuit breaker + concurrency gates
        {Registry, keys: :unique, name: Liteskill.LlmGateway.GateRegistry},
        {DynamicSupervisor, name: Liteskill.LlmGateway.GateSupervisor, strategy: :one_for_one},
        # Periodic sweep of stale LLM token bucket ETS entries
        Liteskill.LlmGateway.TokenBucket.Sweeper,
        # Chat projector - projects events to read-model tables
        Liteskill.Chat.Projector,
        # Periodic sweep for conversations stuck in streaming status
        Liteskill.Chat.StreamRecovery,
        # Schedule tick — checks for due schedules and enqueues runs
        # coveralls-ignore-start
        unless(test_env?(), do: Liteskill.Schedules.ScheduleTick),
        # Desktop shutdown is handled by Tauri's kill_sidecar (SIGTERM/taskkill).
        # No heartbeat socket or ShutdownManager needed.
        # coveralls-ignore-stop
        # Start to serve requests, typically the last entry
        LiteskillWeb.Endpoint
      ]
      |> Enum.reject(&is_nil/1)

    # rest_for_one: if an infrastructure child (Repo, PubSub) crashes,
    # all children started after it (Projector, Endpoint) restart too,
    # re-establishing PubSub subscriptions and DB connections.
    opts = [strategy: :rest_for_one, name: Liteskill.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    LiteskillWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp test_env?, do: Application.get_env(:liteskill, :env) == :test
  defp desktop_mode?, do: Application.get_env(:liteskill, :desktop_mode, false)
end
