defmodule LiteskillWeb.PipelineComponents do
  @moduledoc """
  Function components for the RAG ingest pipeline dashboard.
  """

  use Phoenix.Component
  use Phoenix.VerifiedRoutes, endpoint: LiteskillWeb.Endpoint, router: LiteskillWeb.Router

  import LiteskillWeb.CoreComponents, only: [icon: 1]

  attr :stats, :map, required: true
  attr :rates, :map, required: true
  attr :chart_data, :list, required: true
  attr :jobs, :map, required: true
  attr :job_search, :string, required: true
  attr :scope, :atom, required: true
  attr :is_admin, :boolean, required: true
  attr :window, :atom, required: true

  def pipeline_dashboard(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <header class="px-4 py-3 border-b border-base-300 flex-shrink-0">
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-2">
            <.link navigate={~p"/sources"} class="btn btn-circle btn-ghost btn-sm">
              <.icon name="hero-arrow-left-micro" class="size-5" />
            </.link>
            <h1 class="text-lg font-semibold">RAG Ingest Pipeline</h1>
          </div>
          <div :if={@is_admin} class="flex items-center gap-2">
            <span class="text-sm opacity-60">
              {if @scope == :user, do: "My data", else: "All users"}
            </span>
            <input
              type="checkbox"
              class="toggle toggle-sm toggle-primary"
              checked={@scope == :all}
              phx-click="pipeline_toggle_scope"
            />
          </div>
        </div>
      </header>

      <div class="flex-1 overflow-y-auto p-4 space-y-6">
        <.stats_cards stats={@stats} />
        <.rate_cards rates={@rates} window={@window} />
        <.chart_section chart_data={@chart_data} />
        <.jobs_section jobs={@jobs} job_search={@job_search} />
      </div>
    </div>
    """
  end

  attr :stats, :map, required: true

  defp stats_cards(assigns) do
    ~H"""
    <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-3">
      <.stat_card label="Sources" value={@stats.source_count} icon="hero-folder-micro" />
      <.stat_card label="Documents" value={@stats.document_count} icon="hero-document-text-micro" />
      <.stat_card label="Chunks" value={@stats.chunk_count} icon="hero-squares-2x2-micro" />
      <.stat_card label="Jobs OK" value={@stats.jobs_ok} icon="hero-check-micro" color="success" />
      <.stat_card
        label="Jobs Failed"
        value={@stats.jobs_failed}
        icon="hero-x-mark-micro"
        color="error"
      />
      <.stat_card
        label="Embed Calls"
        value={@stats.embed_requests}
        icon="hero-arrow-path-micro"
      />
      <.stat_card
        label="Embed Errors"
        value={@stats.embed_errors}
        icon="hero-exclamation-triangle-micro"
        color="warning"
      />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :icon, :string, required: true
  attr :color, :string, default: nil

  defp stat_card(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow-sm">
      <div class="card-body p-3">
        <div class="flex items-center gap-2">
          <.icon name={@icon} class={["size-4 opacity-60", badge_color(@color)]} />
          <span class="text-xs opacity-60 uppercase tracking-wide">{@label}</span>
        </div>
        <div class="text-2xl font-bold">{format_number(@value)}</div>
      </div>
    </div>
    """
  end

  attr :rates, :map, required: true
  attr :window, :atom, required: true

  defp rate_cards(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow-sm">
      <div class="card-body p-4">
        <div class="flex items-center justify-between mb-3">
          <h2 class="card-title text-sm">Failure & Retry Rates</h2>
          <div class="join">
            <button
              :for={w <- [:hour, :day, :week]}
              class={["join-item btn btn-xs", if(@window == w, do: "btn-primary", else: "btn-ghost")]}
              phx-click="pipeline_select_window"
              phx-value-window={w}
            >
              {window_label(w)}
            </button>
          </div>
        </div>
        <%= if window_data = @rates[@window] do %>
          <div class="grid grid-cols-3 gap-4">
            <div>
              <div class="text-xs opacity-60">Job Failure</div>
              <div class="text-lg font-semibold">{window_data.job_failure_rate}%</div>
            </div>
            <div>
              <div class="text-xs opacity-60">Job Retry</div>
              <div class="text-lg font-semibold">{window_data.job_retry_rate}%</div>
            </div>
            <div>
              <div class="text-xs opacity-60">Embed Failure</div>
              <div class="text-lg font-semibold">{window_data.embed_failure_rate}%</div>
            </div>
          </div>
        <% else %>
          <div class="text-sm opacity-60">No data for this window</div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :chart_data, :list, required: true

  defp chart_section(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow-sm">
      <div class="card-body p-4">
        <h2 class="card-title text-sm mb-3">Chunks per Source</h2>
        <%= if @chart_data == [] do %>
          <div class="text-sm opacity-60 text-center py-8">No chunk data yet</div>
        <% else %>
          <div
            id="pipeline-chart"
            phx-hook="PipelineChart"
            phx-update="ignore"
            data-chart={Jason.encode!(@chart_data)}
            class="max-w-md mx-auto"
          >
            <canvas></canvas>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :jobs, :map, required: true
  attr :job_search, :string, required: true

  defp jobs_section(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow-sm">
      <div class="card-body p-4">
        <div class="flex items-center justify-between mb-3">
          <h2 class="card-title text-sm">Ingest Jobs</h2>
          <form phx-change="pipeline_search_jobs" class="join">
            <input
              type="text"
              name="search"
              placeholder="Search by URL..."
              value={@job_search}
              class="input input-xs input-bordered join-item w-48"
              phx-debounce="300"
            />
          </form>
        </div>

        <div class="overflow-x-auto">
          <table class="table table-xs">
            <thead>
              <tr>
                <th>URL</th>
                <th>State</th>
                <th>Attempt</th>
                <th>Started</th>
                <th>Completed</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={job <- @jobs.jobs}>
                <td class="max-w-xs truncate" title={get_in(job, [:args, "url"]) || ""}>
                  {get_in(job, [:args, "url"]) || "—"}
                </td>
                <td><.job_badge state={job.state} /></td>
                <td>{job.attempt}/{job.max_attempts}</td>
                <td class="text-xs opacity-60">{format_dt(job.inserted_at)}</td>
                <td class="text-xs opacity-60">{format_dt(job.completed_at)}</td>
              </tr>
              <tr :if={@jobs.jobs == []}>
                <td colspan="5" class="text-center opacity-60 py-4">No jobs found</td>
              </tr>
            </tbody>
          </table>
        </div>

        <div :if={@jobs.total_pages > 1} class="flex justify-center items-center gap-1 mt-3">
          <%= for p <- page_window(@jobs.page, @jobs.total_pages) do %>
            <%= if p == :ellipsis do %>
              <span class="px-1 text-xs opacity-40">&hellip;</span>
            <% else %>
              <button
                class={["btn btn-xs", if(p == @jobs.page, do: "btn-primary", else: "btn-ghost")]}
                phx-click="pipeline_jobs_page"
                phx-value-page={p}
              >
                {p}
              </button>
            <% end %>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr :state, :string, required: true

  defp job_badge(assigns) do
    ~H"""
    <span class={["badge badge-xs", job_badge_class(@state)]}>{@state}</span>
    """
  end

  # --- Helpers ---

  defp job_badge_class("completed"), do: "badge-success"
  defp job_badge_class("executing"), do: "badge-info"
  defp job_badge_class("available"), do: "badge-info"
  defp job_badge_class("scheduled"), do: "badge-info"
  defp job_badge_class("retryable"), do: "badge-warning"
  defp job_badge_class("discarded"), do: "badge-error"
  defp job_badge_class(_), do: "badge-ghost"

  defp badge_color("success"), do: "text-success"
  defp badge_color("error"), do: "text-error"
  defp badge_color("warning"), do: "text-warning"
  defp badge_color(_), do: ""

  defp window_label(:hour), do: "1h"
  defp window_label(:day), do: "24h"
  defp window_label(:week), do: "7d"

  defp format_number(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_number(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_number(n), do: "#{n}"

  defp page_window(_current, total) when total <= 7, do: Enum.to_list(1..total)

  defp page_window(current, total) do
    neighbors = [current - 1, current, current + 1]

    pages =
      ([1] ++ neighbors ++ [total])
      |> Enum.uniq()
      |> Enum.filter(&(&1 >= 1 and &1 <= total))
      |> Enum.sort()

    pages
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce([hd(pages)], fn [a, b], acc ->
      if b - a > 1, do: acc ++ [:ellipsis, b], else: acc ++ [b]
    end)
  end

  defp format_dt(nil), do: "—"

  defp format_dt(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  defp format_dt(%NaiveDateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  defp format_dt(_), do: "—"
end
