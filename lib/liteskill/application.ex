defmodule Liteskill.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  # coveralls-ignore-start
  @env Application.compile_env(:liteskill, :env)
  # coveralls-ignore-stop

  @impl true
  def start(_type, _args) do
    Liteskill.Crypto.validate_key!()
    LiteskillWeb.Plugs.RateLimiter.create_table()

    children =
      [
        LiteskillWeb.Telemetry,
        Liteskill.Repo,
        {DNSCluster, query: Application.get_env(:liteskill, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Liteskill.PubSub},
        # coveralls-ignore-next-line
        if(@env != :test, do: Liteskill.Rag.EmbedQueue),
        {Oban, Application.fetch_env!(:liteskill, Oban)},
        # Ensure root admin account exists on boot (skip in test — sandbox not available)
        # coveralls-ignore-start
        if(@env != :test,
          do:
            {Task,
             fn ->
               Liteskill.Accounts.ensure_admin_user()
               Liteskill.Rbac.ensure_system_roles()
               Liteskill.LlmProviders.ensure_env_providers()
               Liteskill.Settings.get()
             end}
        ),
        # coveralls-ignore-stop
        # Periodic sweep of stale rate limiter ETS buckets
        LiteskillWeb.Plugs.RateLimiter.Sweeper,
        # Task supervisor for LLM streaming and other async work
        {Task.Supervisor, name: Liteskill.TaskSupervisor},
        # Chat projector - projects events to read-model tables
        Liteskill.Chat.Projector,
        # Periodic sweep for conversations stuck in streaming status
        Liteskill.Chat.StreamRecovery,
        # Schedule tick — checks for due schedules and enqueues runs
        # coveralls-ignore-start
        if(@env != :test, do: Liteskill.Schedules.ScheduleTick),
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
end
