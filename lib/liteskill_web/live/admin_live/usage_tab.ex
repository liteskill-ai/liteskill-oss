defmodule LiteskillWeb.AdminLive.UsageTab do
  @moduledoc false

  use LiteskillWeb, :html

  import LiteskillWeb.AdminLive.Helpers, only: [require_admin: 2]
  import LiteskillWeb.FormatHelpers

  alias Liteskill.Accounts
  alias Liteskill.Groups
  alias Liteskill.Usage

  def assigns do
    [
      admin_usage_data: %{},
      admin_usage_period: "30d"
    ]
  end

  def load_data(socket) do
    period = socket.assigns[:admin_usage_period] || "30d"
    usage_data = load_usage_data(period)

    assign(socket,
      page_title: "Usage Analytics",
      admin_usage_data: usage_data,
      admin_usage_period: period
    )
  end

  def handle_event("admin_usage_period", %{"period" => period}, socket) do
    require_admin(socket, fn ->
      usage_data = load_usage_data(period)

      {:noreply,
       assign(socket,
         admin_usage_data: usage_data,
         admin_usage_period: period
       )}
    end)
  end

  def render_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <h2 class="text-xl font-semibold">Usage Analytics</h2>
        <div class="flex gap-1">
          <button
            :for={
              {label, value} <- [
                {"7 days", "7d"},
                {"30 days", "30d"},
                {"90 days", "90d"},
                {"All time", "all"}
              ]
            }
            phx-click="admin_usage_period"
            phx-value-period={value}
            class={[
              "btn btn-sm",
              if(@admin_usage_period == value, do: "btn-primary", else: "btn-ghost")
            ]}
          >
            {label}
          </button>
        </div>
      </div>

      <.usage_instance_summary usage={@admin_usage_data[:instance]} />
      <.usage_daily_chart daily={@admin_usage_data[:daily] || []} />
      <.usage_by_model data={@admin_usage_data[:by_model] || []} />
      <.usage_by_user
        data={@admin_usage_data[:by_user] || []}
        user_map={@admin_usage_data[:user_map] || %{}}
      />
      <.usage_by_group data={@admin_usage_data[:group_usage] || []} />

      <.embedding_usage_summary totals={@admin_usage_data[:embedding_totals]} />
      <.embedding_usage_by_model data={@admin_usage_data[:embedding_by_model] || []} />
      <.embedding_usage_by_user
        data={@admin_usage_data[:embedding_by_user] || []}
        user_map={@admin_usage_data[:user_map] || %{}}
      />
    </div>
    """
  end

  # --- Private ---

  defp load_usage_data(period) do
    time_opts = period_to_opts(period)

    instance = Usage.instance_totals(time_opts)
    by_user = Usage.usage_summary(Keyword.put(time_opts, :group_by, :user_id))
    by_model = Usage.usage_summary(Keyword.put(time_opts, :group_by, :model_id))
    daily = Usage.daily_totals(time_opts)

    users = Accounts.list_users()
    user_map = Map.new(users, fn u -> {u.id, u} end)

    groups = Groups.list_all_groups()
    group_ids = Enum.map(groups, & &1.id)
    group_usage_map = Usage.usage_by_groups(group_ids, time_opts)

    group_usage =
      groups
      |> Enum.map(fn group ->
        %{
          group: group,
          usage: Map.get(group_usage_map, group.id, %{total_tokens: 0, call_count: 0})
        }
      end)
      |> Enum.sort_by(fn %{usage: u} -> u.total_tokens end, :desc)

    embedding_totals = Usage.embedding_totals(time_opts)
    embedding_by_model = Usage.embedding_by_model(time_opts)
    embedding_by_user = Usage.embedding_by_user(time_opts)

    %{
      instance: instance,
      by_user: by_user,
      by_model: by_model,
      daily: daily,
      user_map: user_map,
      group_usage: group_usage,
      embedding_totals: embedding_totals,
      embedding_by_model: embedding_by_model,
      embedding_by_user: embedding_by_user
    }
  end

  defp period_to_opts("7d") do
    [from: DateTime.add(DateTime.utc_now(), -7, :day)]
  end

  defp period_to_opts("30d") do
    [from: DateTime.add(DateTime.utc_now(), -30, :day)]
  end

  defp period_to_opts("90d") do
    [from: DateTime.add(DateTime.utc_now(), -90, :day)]
  end

  defp period_to_opts("all"), do: []

  # --- Components ---

  defp usage_instance_summary(assigns) do
    usage = assigns[:usage] || %{}
    assigns = assign(assigns, :usage, usage)

    ~H"""
    <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
      <.stat_card label="Total Cost" value={format_cost(@usage[:total_cost])} />
      <.stat_card label="Input Cost" value={format_cost(@usage[:input_cost])} />
      <.stat_card label="Output Cost" value={format_cost(@usage[:output_cost])} />
      <.stat_card label="API Calls" value={format_number(@usage[:call_count] || 0)} />
      <.stat_card label="Total Tokens" value={format_number(@usage[:total_tokens] || 0)} />
      <.stat_card label="Input Tokens" value={format_number(@usage[:input_tokens] || 0)} />
      <.stat_card label="Output Tokens" value={format_number(@usage[:output_tokens] || 0)} />
      <.stat_card label="Reasoning Tokens" value={format_number(@usage[:reasoning_tokens] || 0)} />
      <.stat_card label="Cached Tokens" value={format_number(@usage[:cached_tokens] || 0)} />
      <.stat_card
        label="Cache Hit Rate"
        value={format_percentage(@usage[:cached_tokens] || 0, @usage[:input_tokens] || 0)}
      />
    </div>
    """
  end

  defp stat_card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body p-4">
        <div class="text-sm text-base-content/60">{@label}</div>
        <div class="text-2xl font-bold">{@value}</div>
      </div>
    </div>
    """
  end

  defp usage_daily_chart(assigns) do
    ~H"""
    <div :if={@daily != []} class="card bg-base-100 shadow">
      <div class="card-body">
        <h3 class="card-title text-base mb-4">Daily Usage</h3>
        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Date</th>
                <th class="text-right">Tokens</th>
                <th class="text-right">In Cost</th>
                <th class="text-right">Out Cost</th>
                <th class="text-right">Total Cost</th>
                <th class="text-right">Calls</th>
                <th>Volume</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={day <- @daily}>
                <td class="font-mono text-sm">{format_date(day.date)}</td>
                <td class="text-right">{format_number(day.total_tokens)}</td>
                <td class="text-right">{format_cost(day.input_cost)}</td>
                <td class="text-right">{format_cost(day.output_cost)}</td>
                <td class="text-right">{format_cost(day.total_cost)}</td>
                <td class="text-right">{day.call_count}</td>
                <td>
                  <div class="w-32 bg-base-200 rounded-full h-2">
                    <div
                      class="bg-primary h-2 rounded-full"
                      style={"width: #{bar_width(day.total_tokens, @daily)}%"}
                    >
                    </div>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp usage_by_model(assigns) do
    ~H"""
    <div :if={@data != []} class="card bg-base-100 shadow">
      <div class="card-body">
        <h3 class="card-title text-base mb-4">Usage by Model</h3>
        <div class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>Model</th>
                <th class="text-right">Tokens</th>
                <th class="text-right">Input</th>
                <th class="text-right">Output</th>
                <th class="text-right">In Cost</th>
                <th class="text-right">Out Cost</th>
                <th class="text-right">Total Cost</th>
                <th class="text-right">Calls</th>
                <th>Share</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @data}>
                <td class="font-mono text-sm max-w-xs truncate">{row.model_id}</td>
                <td class="text-right">{format_number(row.total_tokens)}</td>
                <td class="text-right">{format_number(row.input_tokens)}</td>
                <td class="text-right">{format_number(row.output_tokens)}</td>
                <td class="text-right">{format_cost(row.input_cost)}</td>
                <td class="text-right">{format_cost(row.output_cost)}</td>
                <td class="text-right">{format_cost(row.total_cost)}</td>
                <td class="text-right">{row.call_count}</td>
                <td>
                  <div class="w-24 bg-base-200 rounded-full h-2">
                    <div
                      class="bg-secondary h-2 rounded-full"
                      style={"width: #{token_share(row.total_tokens, @data)}%"}
                    >
                    </div>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp usage_by_user(assigns) do
    ~H"""
    <div :if={@data != []} class="card bg-base-100 shadow">
      <div class="card-body">
        <h3 class="card-title text-base mb-4">Usage by User</h3>
        <div class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>User</th>
                <th class="text-right">Tokens</th>
                <th class="text-right">Input</th>
                <th class="text-right">Output</th>
                <th class="text-right">In Cost</th>
                <th class="text-right">Out Cost</th>
                <th class="text-right">Total Cost</th>
                <th class="text-right">Calls</th>
                <th>Share</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- Enum.sort_by(@data, & &1.total_tokens, :desc)}>
                <td>
                  <span :if={@user_map[row.user_id]} class="text-sm">
                    {@user_map[row.user_id].email}
                  </span>
                  <span :if={!@user_map[row.user_id]} class="text-sm text-base-content/50">
                    Unknown
                  </span>
                </td>
                <td class="text-right">{format_number(row.total_tokens)}</td>
                <td class="text-right">{format_number(row.input_tokens)}</td>
                <td class="text-right">{format_number(row.output_tokens)}</td>
                <td class="text-right">{format_cost(row.input_cost)}</td>
                <td class="text-right">{format_cost(row.output_cost)}</td>
                <td class="text-right">{format_cost(row.total_cost)}</td>
                <td class="text-right">{row.call_count}</td>
                <td>
                  <div class="w-24 bg-base-200 rounded-full h-2">
                    <div
                      class="bg-accent h-2 rounded-full"
                      style={"width: #{token_share(row.total_tokens, @data)}%"}
                    >
                    </div>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp usage_by_group(assigns) do
    ~H"""
    <div :if={@data != []} class="card bg-base-100 shadow">
      <div class="card-body">
        <h3 class="card-title text-base mb-4">Usage by Group</h3>
        <div class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>Group</th>
                <th class="text-right">Members</th>
                <th class="text-right">Tokens</th>
                <th class="text-right">In Cost</th>
                <th class="text-right">Out Cost</th>
                <th class="text-right">Total Cost</th>
                <th class="text-right">Calls</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={%{group: group, usage: usage} <- @data}>
                <td class="font-medium">{group.name}</td>
                <td class="text-right">{length(group.memberships)}</td>
                <td class="text-right">{format_number(usage.total_tokens)}</td>
                <td class="text-right">{format_cost(usage.input_cost)}</td>
                <td class="text-right">{format_cost(usage.output_cost)}</td>
                <td class="text-right">{format_cost(usage.total_cost)}</td>
                <td class="text-right">{usage.call_count}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp embedding_usage_summary(%{totals: nil} = assigns) do
    ~H"""
    """
  end

  defp embedding_usage_summary(assigns) do
    error_rate =
      if assigns.totals.request_count > 0 do
        Float.round(assigns.totals.error_count / assigns.totals.request_count * 100, 1)
      else
        0.0
      end

    avg_ms = trunc(Decimal.to_float(assigns.totals.avg_latency_ms))
    assigns = assign(assigns, error_rate: error_rate, avg_ms: avg_ms)

    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body">
        <h3 class="card-title text-base mb-4">Embedding & Rerank Usage</h3>
        <div class="grid grid-cols-2 md:grid-cols-6 gap-4">
          <.stat_card label="Requests" value={format_number(@totals.request_count)} />
          <.stat_card label="Total Tokens" value={format_number(@totals.total_tokens)} />
          <.stat_card label="Inputs Processed" value={format_number(@totals.total_inputs)} />
          <.stat_card label="Est. Cost" value={format_cost(@totals.estimated_cost)} />
          <.stat_card label="Avg Latency" value={"#{@avg_ms}ms"} />
          <.stat_card label="Error Rate" value={"#{@error_rate}%"} />
        </div>
      </div>
    </div>
    """
  end

  defp embedding_usage_by_model(assigns) do
    ~H"""
    <div :if={@data != []} class="card bg-base-100 shadow">
      <div class="card-body">
        <h3 class="card-title text-base mb-4">Embedding Usage by Model</h3>
        <div class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>Model</th>
                <th class="text-right">Requests</th>
                <th class="text-right">Tokens</th>
                <th class="text-right">Inputs</th>
                <th class="text-right">Est. Cost</th>
                <th class="text-right">Errors</th>
                <th class="text-right">Avg Latency</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @data}>
                <td class="font-medium font-mono text-xs">{row.model_id}</td>
                <td class="text-right">{format_number(row.request_count)}</td>
                <td class="text-right">{format_number(row.total_tokens)}</td>
                <td class="text-right">{format_number(row.total_inputs)}</td>
                <td class="text-right">{format_cost(row.estimated_cost)}</td>
                <td class="text-right">{row.error_count}</td>
                <td class="text-right">{trunc(Decimal.to_float(row.avg_latency_ms))}ms</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp embedding_usage_by_user(assigns) do
    ~H"""
    <div :if={@data != []} class="card bg-base-100 shadow">
      <div class="card-body">
        <h3 class="card-title text-base mb-4">Embedding Usage by User</h3>
        <div class="overflow-x-auto">
          <table class="table">
            <thead>
              <tr>
                <th>User</th>
                <th class="text-right">Requests</th>
                <th class="text-right">Tokens</th>
                <th class="text-right">Inputs</th>
                <th class="text-right">Est. Cost</th>
                <th class="text-right">Errors</th>
                <th class="text-right">Avg Latency</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @data}>
                <td class="font-medium">
                  {if user = @user_map[row.user_id], do: user.email, else: "Unknown"}
                </td>
                <td class="text-right">{format_number(row.request_count)}</td>
                <td class="text-right">{format_number(row.total_tokens)}</td>
                <td class="text-right">{format_number(row.total_inputs)}</td>
                <td class="text-right">{format_cost(row.estimated_cost)}</td>
                <td class="text-right">{row.error_count}</td>
                <td class="text-right">{trunc(Decimal.to_float(row.avg_latency_ms))}ms</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp bar_width(_tokens, []), do: 0

  defp bar_width(tokens, daily) do
    max = daily |> Enum.map(& &1.total_tokens) |> Enum.max(fn -> 1 end)
    if max == 0, do: 0, else: Float.round(tokens / max * 100, 0)
  end

  defp token_share(_tokens, []), do: 0

  defp token_share(tokens, data) do
    total = data |> Enum.map(& &1.total_tokens) |> Enum.sum()
    if total == 0, do: 0, else: Float.round(tokens / total * 100, 0)
  end
end
