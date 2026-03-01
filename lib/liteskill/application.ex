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

    # coveralls-ignore-start
    children =
      Enum.reject(
        [
          LiteskillWeb.Telemetry,
          if(desktop_mode?(), do: Liteskill.Desktop.PostgresManager),
          Liteskill.Repo,
          {DNSCluster, query: Application.get_env(:liteskill, :dns_cluster_query) || :ignore},
          {Phoenix.PubSub, name: Liteskill.PubSub},
          if(!test_env?(), do: Liteskill.Rag.EmbedQueue),
          {Oban, Application.fetch_env!(:liteskill, Oban)},
          if(!test_env?(),
            do:
              {Task,
               fn ->
                 Liteskill.Accounts.ensure_admin_user()
                 Liteskill.Rbac.ensure_system_roles()
                 Liteskill.LlmProviders.ensure_env_providers()
                 Liteskill.Settings.get()
                 Liteskill.DemoSeeds.ensure_demo_agents()

                 if Liteskill.SingleUser.enabled?(), do: Liteskill.SingleUser.auto_provision_admin()
               end}
          ),
          Liteskill.OpenRouter.StateStore,
          LiteskillWeb.Plugs.RateLimiter.Sweeper,
          {Task.Supervisor, name: Liteskill.TaskSupervisor},
          Liteskill.Chat.StreamRegistry,
          {Registry, keys: :unique, name: Liteskill.LlmGateway.GateRegistry},
          {DynamicSupervisor, name: Liteskill.LlmGateway.GateSupervisor, strategy: :one_for_one},
          Liteskill.LlmGateway.TokenBucket.Sweeper,
          Liteskill.Chat.Projector,
          Liteskill.Chat.StreamRecovery,
          if(!test_env?(), do: Liteskill.Schedules.ScheduleTick),
          Liteskill.Accounts.SessionSweeper,
          if(saml_configured?(), do: {Samly.Provider, []}),
          LiteskillWeb.Endpoint
        ],
        &is_nil/1
      )

    # coveralls-ignore-stop

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
  defp saml_configured?, do: Application.get_env(:liteskill, :saml_configured, false)
end
