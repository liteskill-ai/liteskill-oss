defmodule LiteskillWeb.SourcesComponents do
  @moduledoc """
  Function components for data sources, RAG, and citation UI.
  """

  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: LiteskillWeb.Endpoint,
    router: LiteskillWeb.Router,
    statics: LiteskillWeb.static_paths()

  import LiteskillWeb.CoreComponents, only: [icon: 1]

  attr :source, :map, required: true

  def source_card(assigns) do
    assigns = assign(assigns, :builtin?, Map.get(assigns.source, :builtin, false))

    assigns =
      assign(
        assigns,
        :needs_config?,
        !Map.get(assigns.source, :builtin, false) &&
          (!is_map(Map.get(assigns.source, :metadata)) ||
             Map.get(assigns.source, :metadata) == %{})
      )

    ~H"""
    <%= if @needs_config? do %>
      <button
        phx-click="open_configure_source"
        phx-value-source-id={@source.id}
        class="block w-full text-left"
      >
        <div class="card bg-warning/10 border-2 border-warning shadow-sm hover:border-warning hover:shadow-md transition-all cursor-pointer">
          <div class="card-body p-4">
            <div class="flex items-start justify-between gap-2">
              <div class="flex-1 min-w-0">
                <div class="flex items-center gap-2">
                  <.icon name={source_icon(@source)} class="size-4 text-base-content/60" />
                  <h3 class="font-semibold text-sm truncate">{@source.name}</h3>
                </div>
                <p class="text-xs text-base-content/70 mt-1">
                  Click to configure connection settings
                </p>
              </div>
              <div class="flex items-center gap-1">
                <span class="badge badge-sm badge-warning">needs-configuration</span>
              </div>
            </div>
            <div class="flex items-center justify-between mt-2">
              <span class="text-xs text-base-content/50">
                {Map.get(@source, :document_count, 0)} {if Map.get(@source, :document_count, 0) == 1,
                  do: "document",
                  else: "documents"}
              </span>
            </div>
          </div>
        </div>
      </button>
    <% else %>
      <.link navigate={~p"/sources/#{source_url_id(@source)}"} class="block">
        <div class="card bg-base-100 border border-base-300 shadow-sm hover:border-primary/50 hover:shadow-md transition-all cursor-pointer">
          <div class="card-body p-4">
            <div class="flex items-start justify-between gap-2">
              <div class="flex-1 min-w-0">
                <div class="flex items-center gap-2">
                  <.icon name={source_icon(@source)} class="size-4 text-base-content/60" />
                  <h3 class="font-semibold text-sm truncate">{@source.name}</h3>
                </div>
                <p :if={@source.description} class="text-xs text-base-content/70 mt-1 line-clamp-2">
                  {@source.description}
                </p>
              </div>
              <div class="flex items-center gap-1">
                <span :if={@builtin?} class="badge badge-sm badge-primary">built-in</span>
              </div>
            </div>
            <div class="flex items-center justify-between mt-2">
              <span class="text-xs text-base-content/50">
                {Map.get(@source, :document_count, 0)} {if Map.get(@source, :document_count, 0) == 1,
                  do: "document",
                  else: "documents"}
              </span>
            </div>
          </div>
        </div>
      </.link>
    <% end %>
    """
  end

  attr :message, :map, required: true

  def sources_button(assigns) do
    has_sources =
      assigns.message.role == "assistant" &&
        assigns.message.content not in [nil, ""] &&
        assigns.message.rag_sources not in [nil, []]

    assigns = assign(assigns, :has_sources, has_sources)
    count = if has_sources, do: length(assigns.message.rag_sources), else: 0
    assigns = assign(assigns, :count, count)

    ~H"""
    <div
      :if={@has_sources}
      class="flex justify-start mb-4"
    >
      <button
        phx-click="toggle_sources_sidebar"
        phx-value-message-id={@message.id}
        class="btn btn-ghost btn-xs gap-1 text-base-content/50 hover:text-primary"
      >
        <.icon name="hero-document-text-micro" class="size-3.5" /> Sources ({@count})
      </button>
    </div>
    """
  end

  attr :show, :boolean, required: true
  attr :sources, :list, required: true

  def sources_sidebar(assigns) do
    deduped =
      assigns.sources
      |> Enum.uniq_by(fn s -> s["document_id"] end)

    assigns = assign(assigns, :deduped, deduped)

    ~H"""
    <aside
      :if={@show}
      class="w-80 max-sm:fixed max-sm:inset-0 max-sm:w-full max-sm:z-40 flex-shrink-0 border-l border-base-300 bg-base-100 flex flex-col overflow-hidden"
    >
      <div class="flex items-center justify-between p-3 border-b border-base-300">
        <h3 class="font-semibold text-sm">Sources</h3>
        <button phx-click="close_sources_sidebar" class="btn btn-ghost btn-sm btn-square">
          <.icon name="hero-x-mark-micro" class="size-5" />
        </button>
      </div>
      <div class="flex-1 overflow-y-auto p-3 space-y-2">
        <.source_item
          :for={{source, idx} <- Enum.with_index(@deduped)}
          source={source}
          rank={idx + 1}
        />
      </div>
    </aside>
    """
  end

  attr :source, :map, required: true
  attr :rank, :integer, required: true

  def source_item(assigns) do
    ~H"""
    <button
      phx-click="show_source_modal"
      phx-value-chunk-id={@source["chunk_id"]}
      data-doc-id={@source["document_id"]}
      class="source-item w-full text-left border border-base-300 rounded-lg p-2 hover:border-primary/40 transition-colors cursor-pointer"
    >
      <div class="flex items-center gap-2">
        <span class="badge badge-sm badge-primary font-mono">#{@rank}</span>
        <span class="text-xs font-medium truncate">{@source["document_title"]}</span>
      </div>
      <p class="text-xs text-base-content/60 mt-1 line-clamp-2">
        {String.slice(@source["content"] || "", 0..120)}
      </p>
      <div class="flex items-center gap-2 mt-1 text-[10px] text-base-content/40">
        <span :if={@source["source_name"]}>via {@source["source_name"]}</span>
        <span :if={@source["relevance_score"]}>
          {Float.round(@source["relevance_score"] * 100, 1)}%
        </span>
      </div>
    </button>
    """
  end

  attr :show, :boolean, required: true
  attr :source, :map, required: true

  def source_detail_modal(assigns) do
    ~H"""
    <div
      :if={@show}
      class="fixed inset-0 z-50 flex items-center justify-center"
      phx-window-keydown="close_source_modal"
      phx-key="Escape"
    >
      <div class="fixed inset-0 bg-black/50" phx-click="close_source_modal" />
      <div class="relative bg-base-100 rounded-xl shadow-xl w-full max-w-2xl max-h-[80vh] flex flex-col z-10 mx-4">
        <div class="flex items-center justify-between p-4 border-b border-base-300">
          <h3 class="font-semibold text-sm truncate pr-4">
            {@source["document_title"] || "Source"}
          </h3>
          <button phx-click="close_source_modal" class="btn btn-ghost btn-sm btn-square">
            <.icon name="hero-x-mark-micro" class="size-5" />
          </button>
        </div>
        <div class="flex-1 overflow-y-auto p-4 space-y-3">
          <div class="bg-base-200/50 rounded-lg p-3">
            <pre class="text-xs whitespace-pre-wrap font-mono leading-relaxed">{@source["content"]}</pre>
          </div>
          <div class="flex items-center gap-3 text-xs text-base-content/50">
            <span :if={@source["source_name"]}>Source: {@source["source_name"]}</span>
            <span :if={@source["position"]}>Position: {@source["position"]}</span>
            <span :if={@source["relevance_score"]}>
              Relevance: {Float.round(@source["relevance_score"] * 100, 1)}%
            </span>
          </div>
        </div>
        <div :if={@source["source_uri"]} class="p-4 border-t border-base-300">
          <.link navigate={@source["source_uri"]} class="btn btn-primary btn-sm w-full gap-1">
            <.icon name="hero-arrow-top-right-on-square-micro" class="size-4" /> Go to source document
          </.link>
        </div>
      </div>
    </div>
    """
  end

  attr :show, :boolean, required: true
  attr :collections, :list, required: true
  attr :results, :list, required: true
  attr :loading, :boolean, required: true
  attr :error, :any, required: true

  def rag_query_modal(assigns) do
    ~H"""
    <div
      :if={@show}
      id="rag-query-modal"
      class="fixed inset-0 z-50 flex items-center justify-center"
      phx-mounted={@show && Phoenix.LiveView.JS.focus_first(to: "#rag-query-content")}
    >
      <div class="fixed inset-0 bg-black/50" phx-click="close_rag_query" />
      <div
        id="rag-query-content"
        class="relative bg-base-100 rounded-xl shadow-xl w-full max-w-2xl mx-4 max-h-[90vh] flex flex-col"
      >
        <div class="flex items-center justify-between p-4 border-b border-base-300">
          <h3 class="text-lg font-semibold">RAG Query</h3>
          <button phx-click="close_rag_query" class="btn btn-ghost btn-sm btn-square">
            <.icon name="hero-x-mark-micro" class="size-5" />
          </button>
        </div>

        <div class="p-4 border-b border-base-300">
          <%= if @collections == [] do %>
            <p class="text-base-content/50 text-sm text-center py-4">
              No RAG collections found. Ingest some documents first.
            </p>
          <% else %>
            <form phx-submit="rag_search" class="space-y-3">
              <div class="form-control">
                <select
                  name="collection_id"
                  class="select select-bordered select-sm w-full"
                >
                  <option :for={coll <- @collections} value={coll.id}>
                    {coll.name}
                  </option>
                </select>
              </div>
              <div class="flex gap-2">
                <input
                  type="text"
                  name="query"
                  placeholder="Enter search query..."
                  class="input input-bordered input-sm flex-1"
                  autocomplete="off"
                />
                <button type="submit" class="btn btn-primary btn-sm" disabled={@loading}>
                  <%= if @loading do %>
                    <span class="loading loading-spinner loading-xs" /> Searching...
                  <% else %>
                    <.icon name="hero-magnifying-glass-micro" class="size-4" /> Search
                  <% end %>
                </button>
              </div>
            </form>
          <% end %>
        </div>

        <div class="flex-1 overflow-y-auto p-4 space-y-3">
          <div :if={@error} class="alert alert-error text-sm">
            {@error}
          </div>

          <div :if={@loading} class="text-center py-8 text-base-content/50">
            <span class="loading loading-spinner loading-md" />
            <p class="mt-2 text-sm">Embedding query and searching...</p>
          </div>

          <div
            :if={!@loading && @results == [] && !@error}
            class="text-center py-8 text-base-content/50 text-sm"
          >
            Enter a query to search your RAG collections.
          </div>

          <div :if={!@loading && @results != []} class="space-y-2">
            <p class="text-xs text-base-content/50 font-medium">
              {length(@results)} results
            </p>

            <.rag_result_card
              :for={{result, idx} <- Enum.with_index(@results)}
              result={result}
              rank={idx + 1}
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :result, :map, required: true
  attr :rank, :integer, required: true

  def rag_result_card(assigns) do
    ~H"""
    <div class="border border-base-300 rounded-lg overflow-hidden">
      <div class="flex items-center justify-between px-3 py-2 bg-base-200/50 text-xs">
        <div class="flex items-center gap-2">
          <span class="badge badge-sm badge-primary font-mono">#{@rank}</span>
          <span class="font-medium text-base-content/70">
            {if @result.chunk.document, do: @result.chunk.document.title, else: "Unknown"}
          </span>
          <span :if={source_name(@result)} class="text-base-content/50">
            via {source_name(@result)}
          </span>
        </div>
        <span :if={@result.relevance_score} class="font-mono text-base-content/60">
          {Float.round(@result.relevance_score * 100, 1)}%
        </span>
      </div>
      <div class="px-3 py-2">
        <pre class="text-xs text-base-content/80 whitespace-pre-wrap font-mono leading-relaxed max-h-48 overflow-y-auto">{@result.chunk.content}</pre>
      </div>
      <div class="px-3 py-1.5 bg-base-200/30 text-[10px] text-base-content/40 flex gap-3">
        <span>Position: {@result.chunk.position}</span>
        <span :if={@result.chunk.token_count}>Tokens: {@result.chunk.token_count}</span>
      </div>
    </div>
    """
  end

  def add_source_card(assigns) do
    ~H"""
    <button phx-click="open_add_source" class="block w-full text-left">
      <div class="card bg-base-100 border-2 border-dashed border-base-300 shadow-sm hover:border-primary/50 hover:shadow-md transition-all cursor-pointer">
        <div class="card-body p-4 flex flex-col items-center justify-center min-h-[100px]">
          <.icon name="hero-plus-micro" class="size-8 text-base-content/30" />
          <span class="text-sm text-base-content/50 mt-1">Add Data Source</span>
        </div>
      </div>
    </button>
    """
  end

  attr :show, :boolean, required: true
  attr :source_types, :list, required: true

  def add_source_modal(assigns) do
    ~H"""
    <div
      :if={@show}
      class="fixed inset-0 z-50 flex items-center justify-center"
      phx-window-keydown="close_add_source"
      phx-key="Escape"
    >
      <div class="fixed inset-0 bg-black/50" phx-click="close_add_source" />
      <div class="relative bg-base-100 rounded-xl shadow-xl w-full max-w-md max-h-[80vh] flex flex-col z-10 mx-4">
        <div class="flex items-center justify-between p-4 border-b border-base-300">
          <h3 class="text-lg font-semibold">Add Data Source</h3>
          <button phx-click="close_add_source" class="btn btn-ghost btn-sm btn-square">
            <.icon name="hero-x-mark-micro" class="size-5" />
          </button>
        </div>
        <div class="flex-1 overflow-y-auto p-4">
          <p class="text-base-content/70 text-sm mb-4">
            Select a data source type to add.
          </p>
          <div class="grid grid-cols-2 gap-3">
            <button
              :for={source_type <- @source_types}
              phx-click="add_source"
              phx-value-source-type={source_type.source_type}
              phx-value-name={source_type.name}
              class="flex flex-col items-center justify-center gap-2 p-4 rounded-xl border-2 border-base-300 hover:border-primary hover:bg-primary/5 transition-all cursor-pointer"
            >
              <.icon name="hero-folder-micro" class="size-6 text-base-content/60" />
              <span class="text-sm font-medium">{source_type.name}</span>
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :show, :boolean, required: true
  attr :source, :map, required: true
  attr :config_fields, :list, required: true
  attr :config_form, :any, required: true

  def configure_source_modal(assigns) do
    ~H"""
    <div
      :if={@show}
      class="fixed inset-0 z-50 flex items-center justify-center"
      phx-window-keydown="close_configure_source"
      phx-key="Escape"
    >
      <div class="fixed inset-0 bg-black/50" phx-click="close_configure_source" />
      <div class="relative bg-base-100 rounded-xl shadow-xl w-full max-w-lg max-h-[90vh] flex flex-col z-10 mx-4">
        <div class="flex items-center justify-between p-4 border-b border-base-300">
          <h3 class="text-lg font-semibold">Configure {@source.name}</h3>
          <button phx-click="close_configure_source" class="btn btn-ghost btn-sm btn-square">
            <.icon name="hero-x-mark-micro" class="size-5" />
          </button>
        </div>
        <div class="flex-1 overflow-y-auto p-4">
          <p class="text-base-content/70 text-sm mb-4">
            Enter connection details for {@source.name}.
          </p>

          <form phx-submit="save_source_config" class="space-y-4">
            <input type="hidden" name="source_id" value={@source.id} />
            <div :for={field <- @config_fields} class="form-control">
              <label class="label"><span class="label-text">{field.label}</span></label>
              <%= if field.type == :textarea do %>
                <textarea
                  name={"config[#{field.key}]"}
                  placeholder={field.placeholder}
                  class="textarea textarea-bordered w-full"
                  rows="4"
                />
              <% else %>
                <input
                  type={if field.type == :password, do: "password", else: "text"}
                  name={"config[#{field.key}]"}
                  placeholder={field.placeholder}
                  class="input input-bordered w-full"
                />
              <% end %>
            </div>

            <div class="flex gap-3 mt-6">
              <button
                type="button"
                phx-click="close_configure_source"
                class="btn btn-ghost flex-1"
              >
                Cancel
              </button>
              <button type="submit" class="btn btn-primary flex-1">
                Save Configuration
              </button>
            </div>
          </form>
        </div>
      </div>
    </div>
    """
  end

  # --- Helpers ---

  defp source_icon(%{icon: icon}), do: icon
  defp source_icon(_), do: "hero-folder-micro"

  def source_url_id(%{id: "builtin:" <> rest}), do: "builtin-" <> rest
  def source_url_id(%{id: id}), do: id

  defp source_name(%{chunk: %{document: %{source: %{name: name}}}}), do: name
  defp source_name(_), do: nil
end
