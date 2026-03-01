defmodule LiteskillWeb.AdminLive.ServerTab do
  @moduledoc false

  use LiteskillWeb, :html

  import LiteskillWeb.AdminLive.Helpers, only: [require_admin: 2, parse_decimal: 1]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Liteskill.Settings

  def assigns do
    [
      server_settings: nil
    ]
  end

  def load_data(socket) do
    assign(socket,
      page_title: "Server Management",
      server_settings: Settings.get()
    )
  end

  def handle_event("toggle_registration", _params, socket) do
    require_admin(socket, fn ->
      case Settings.toggle_registration() do
        {:ok, settings} ->
          {:noreply, assign(socket, server_settings: settings)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, action_error("toggle registration", reason))}
      end
    end)
  end

  def handle_event("toggle_allow_private_mcp_urls", _params, socket) do
    require_admin(socket, fn ->
      current = socket.assigns.server_settings.allow_private_mcp_urls || false

      case Settings.update(%{allow_private_mcp_urls: !current}) do
        {:ok, settings} ->
          {:noreply, assign(socket, server_settings: settings)}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             action_error("toggle private URLs", reason)
           )}
      end
    end)
  end

  def handle_event("update_mcp_cost_limit", %{"cost_limit" => val}, socket) do
    require_admin(socket, fn ->
      case parse_decimal(val) do
        nil ->
          {:noreply, put_flash(socket, :error, "Invalid cost limit")}

        cost_limit ->
          case Settings.update(%{default_mcp_run_cost_limit: cost_limit}) do
            {:ok, settings} ->
              {:noreply, assign(socket, server_settings: settings)}

            {:error, reason} ->
              {:noreply,
               put_flash(
                 socket,
                 :error,
                 action_error("update cost limit", reason)
               )}
          end
      end
    end)
  end

  def render_tab(assigns) do
    repo_config = Liteskill.Repo.config()
    oban_config = Application.get_env(:liteskill, Oban, [])
    oidc_config = Application.get_env(:ueberauth, Ueberauth.Strategy.OIDCC, [])
    saml_configured = Application.get_env(:liteskill, :saml_configured, false)

    saml_config =
      if saml_configured do
        samly_config = Application.get_env(:samly, Samly.Provider, [])
        idps = Keyword.get(samly_config, :identity_providers, [])
        sps = Keyword.get(samly_config, :service_providers, [])
        idp = List.first(idps) || %{}
        sp = List.first(sps) || %{}
        %{idp_id: idp[:id], sp_id: sp[:id], sp_entity_id: sp[:entity_id]}
      end

    assigns =
      assigns
      |> assign(:repo_config, repo_config)
      |> assign(:oban_config, oban_config)
      |> assign(:oidc_config, oidc_config)
      |> assign(:saml_config, saml_config)

    ~H"""
    <div class="space-y-6">
      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <div class="flex items-center justify-between">
            <div>
              <h2 class="card-title">Setup Wizard</h2>
              <p class="text-sm text-base-content/60 mt-1">
                Re-run the initial setup wizard to update admin password and data source connections.
              </p>
            </div>
            <.link navigate={~p"/admin/setup"} class="btn btn-primary btn-sm gap-1">
              <.icon name="hero-arrow-path-micro" class="size-4" /> Run Setup
            </.link>
          </div>
        </div>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title mb-4">Registration</h2>
          <div class="flex items-center justify-between">
            <div>
              <p class="font-medium">Public Registration</p>
              <p class="text-sm text-base-content/60">
                {if @server_settings && @server_settings.registration_open,
                  do: "Anyone can create an account",
                  else: "Only invited users can create accounts"}
              </p>
            </div>
            <input
              type="checkbox"
              class="toggle toggle-primary"
              checked={@server_settings && @server_settings.registration_open}
              phx-click="toggle_registration"
            />
          </div>
        </div>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title mb-4">Cost Guardrails</h2>
          <div class="flex items-center justify-between">
            <div>
              <p class="font-medium">Default MCP Run Cost Limit</p>
              <p class="text-sm text-base-content/60">
                Maximum cost (USD) for agent runs started via MCP tools.
                Users cannot exceed this limit.
              </p>
            </div>
            <form phx-change="update_mcp_cost_limit" class="flex items-center gap-1">
              <span class="text-sm text-base-content/60">$</span>
              <input
                type="number"
                name="cost_limit"
                step="0.10"
                min="0.10"
                value={
                  @server_settings && @server_settings.default_mcp_run_cost_limit &&
                    Decimal.to_string(@server_settings.default_mcp_run_cost_limit)
                }
                class="input input-bordered input-sm w-24"
                phx-debounce="500"
              />
            </form>
          </div>
        </div>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title mb-4">MCP Security</h2>
          <div class="flex items-center justify-between">
            <div>
              <p class="font-medium">Allow Private URLs</p>
              <p class="text-sm text-base-content/60">
                Allow MCP servers to use private/reserved addresses (localhost, 10.x, 192.168.x, etc.)
                and plain HTTP URLs. Enable this for self-hosted deployments with internal MCP servers.
              </p>
            </div>
            <input
              type="checkbox"
              class="toggle toggle-primary"
              checked={@server_settings && @server_settings.allow_private_mcp_urls}
              phx-click="toggle_allow_private_mcp_urls"
            />
          </div>
        </div>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title mb-4">Database</h2>
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <.info_row label="Host" value={to_string(@repo_config[:hostname] || "—")} />
            <.info_row label="Port" value={to_string(@repo_config[:port] || 5432)} />
            <.info_row label="Database" value={to_string(@repo_config[:database] || "—")} />
            <.info_row label="Pool Size" value={to_string(@repo_config[:pool_size] || "—")} />
          </div>
        </div>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title mb-4">OIDC / SSO</h2>
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <.info_row label="Issuer" value={@oidc_config[:issuer] || "Not configured"} />
            <.info_row label="Client ID" value={@oidc_config[:client_id] || "Not configured"} />
          </div>
        </div>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title mb-4">SAML / SSO</h2>
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <%= if @saml_config do %>
              <.info_row label="Status" value="Configured" />
              <.info_row label="IdP ID" value={@saml_config.idp_id || "—"} />
              <.info_row label="SP ID" value={@saml_config.sp_id || "—"} />
              <.info_row label="SP Entity ID" value={@saml_config.sp_entity_id || "—"} />
            <% else %>
              <.info_row label="Status" value="Not configured" />
            <% end %>
          </div>
        </div>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title mb-4">Job Queues (Oban)</h2>
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <%= for {queue, limit} <- @oban_config[:queues] || [] do %>
              <.info_row label={to_string(queue)} value={"Concurrency: #{limit}"} />
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp info_row(assigns) do
    ~H"""
    <div>
      <div class="text-sm text-base-content/60 mb-1">{@label}</div>
      <div class="font-medium">{@value}</div>
    </div>
    """
  end
end
