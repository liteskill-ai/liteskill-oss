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
  attr :current_user, :map, required: true

  def source_card(assigns) do
    assigns = assign(assigns, :builtin?, Map.get(assigns.source, :builtin, false))

    assigns =
      assign(
        assigns,
        :needs_config?,
        needs_config?(assigns.source)
      )

    assigns =
      assign(
        assigns,
        :can_delete?,
        can_delete_source?(assigns.source, assigns.current_user)
      )

    ~H"""
    <%= if @needs_config? do %>
      <div class="relative group">
        <button
          phx-click="open_configure_source"
          phx-value-source-id={@source.id}
          class="block w-full text-left"
        >
          <div class="card bg-warning/10 border-2 border-warning shadow-sm hover:border-warning hover:shadow-md transition-all cursor-pointer">
            <div class="card-body p-4 h-[120px]">
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
                  {Map.get(@source, :document_count, 0)} {if Map.get(@source, :document_count, 0) ==
                                                               1,
                                                             do: "document",
                                                             else: "documents"}
                </span>
              </div>
            </div>
          </div>
        </button>
        <div class="absolute bottom-2 right-2 flex items-center gap-0.5 opacity-0 group-hover:opacity-100 transition-opacity z-10">
          <button
            :if={@can_delete?}
            phx-click="confirm_delete_source"
            phx-value-id={@source.id}
            class="btn btn-ghost btn-xs text-base-content/40 hover:text-error"
          >
            <.icon name="hero-trash-micro" class="size-3.5" />
          </button>
        </div>
      </div>
    <% else %>
      <div class="relative group">
        <.link navigate={~p"/sources/#{source_url_id(@source)}"} class="block">
          <div class="card bg-base-100 border border-base-300 shadow-sm hover:border-primary/50 hover:shadow-md transition-all cursor-pointer">
            <div class="card-body p-4 h-[120px]">
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
                  {Map.get(@source, :document_count, 0)} {if Map.get(@source, :document_count, 0) ==
                                                               1,
                                                             do: "document",
                                                             else: "documents"}
                </span>
              </div>
            </div>
          </div>
        </.link>
        <div class="absolute bottom-2 right-2 flex items-center gap-0.5 opacity-0 group-hover:opacity-100 transition-opacity z-10">
          <button
            :if={!@builtin?}
            phx-click="open_sharing"
            phx-value-entity-type="source"
            phx-value-entity-id={@source.id}
            class="btn btn-ghost btn-xs text-base-content/40 hover:text-primary"
          >
            <.icon name="hero-share-micro" class="size-3.5" />
          </button>
          <button
            :if={!@builtin?}
            phx-click="open_configure_source"
            phx-value-source-id={@source.id}
            class="btn btn-ghost btn-xs text-base-content/40 hover:text-primary"
          >
            <.icon name="hero-cog-6-tooth-micro" class="size-3.5" />
          </button>
          <button
            :if={@can_delete?}
            phx-click="confirm_delete_source"
            phx-value-id={@source.id}
            class="btn btn-ghost btn-xs text-base-content/40 hover:text-error"
          >
            <.icon name="hero-trash-micro" class="size-3.5" />
          </button>
        </div>
      </div>
    <% end %>
    """
  end

  attr :message, :map, required: true

  def sources_button(assigns) do
    has_sources =
      assigns.message.role == "assistant" &&
        assigns.message.content not in [nil, ""] &&
        assigns.message.rag_sources not in [nil, []]

    has_raw_output =
      assigns.message.role == "assistant" &&
        assigns.message.content not in [nil, ""]

    assigns = assign(assigns, :has_sources, has_sources)
    assigns = assign(assigns, :has_raw_output, has_raw_output)
    count = if has_sources, do: length(assigns.message.rag_sources), else: 0
    assigns = assign(assigns, :count, count)

    ~H"""
    <div
      :if={@has_sources || @has_raw_output}
      class="flex justify-start mb-4"
    >
      <div class="flex items-center gap-1">
        <button
          :if={@has_sources}
          phx-click="toggle_sources_sidebar"
          phx-value-message-id={@message.id}
          class="btn btn-ghost btn-xs gap-1 text-base-content/50 hover:text-primary"
        >
          <.icon name="hero-document-text-micro" class="size-3.5" /> Sources ({@count})
        </button>
        <button
          :if={@has_raw_output}
          phx-click="show_raw_output_modal"
          phx-value-message-id={@message.id}
          class="btn btn-ghost btn-xs gap-1 text-base-content/50 hover:text-primary"
        >
          <.icon name="hero-code-bracket-square-micro" class="size-3.5" /> Raw
        </button>
      </div>
    </div>
    """
  end

  attr :show, :boolean, required: true
  attr :raw_output, :string, default: ""
  attr :message_id, :string, default: nil

  def raw_output_modal(assigns) do
    ~H"""
    <div
      :if={@show}
      id="raw-output-modal"
      class="fixed inset-0 z-50 flex items-center justify-center"
      phx-window-keydown="close_raw_output_modal"
      phx-key="Escape"
    >
      <div class="fixed inset-0 bg-black/50" />
      <div class="relative bg-base-100 rounded-xl shadow-xl w-full max-w-4xl max-h-[85vh] flex flex-col z-10 mx-4">
        <div class="flex items-center justify-between p-4 border-b border-base-300 gap-3">
          <h3 class="font-semibold text-sm">Raw Model Output</h3>
          <div class="flex items-center gap-2">
            <button
              phx-click={
                Phoenix.LiveView.JS.dispatch(
                  "phx:copy",
                  to: "#raw-output-text-#{@message_id || "current"}"
                )
                |> Phoenix.LiveView.JS.push("raw_output_copied")
              }
              class="btn btn-ghost btn-xs gap-1"
            >
              <.icon name="hero-clipboard-document-micro" class="size-3.5" /> Copy
            </button>
            <button phx-click="close_raw_output_modal" class="btn btn-ghost btn-sm btn-square">
              <.icon name="hero-x-mark-micro" class="size-5" />
            </button>
          </div>
        </div>
        <div class="flex-1 overflow-y-auto p-4">
          <div class="prose prose-sm max-w-none">
            <pre class="max-h-[65vh] overflow-auto"><code id={"raw-output-text-#{@message_id || "current"}"}>{@raw_output}</code></pre>
          </div>
        </div>
      </div>
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
        <div :if={@source["source_uri"]} class="px-4 pt-3">
          <.link navigate={@source["source_uri"]} class="btn btn-primary btn-sm w-full gap-1">
            <.icon name="hero-arrow-top-right-on-square-micro" class="size-4" /> Go to source document
          </.link>
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
          <form phx-submit="rag_search" class="space-y-3">
            <div class="form-control">
              <select
                name="collection_id"
                class="select select-bordered select-sm w-full"
              >
                <option value="all">All Collections</option>
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
        <div class="card-body p-4 flex flex-col items-center justify-center h-[120px]">
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
            <%= for source_type <- @source_types do %>
              <% coming_soon = source_type.source_type in ~w(sharepoint confluence jira github gitlab) %>
              <button
                phx-click={unless(coming_soon, do: "add_source")}
                phx-value-source-type={source_type.source_type}
                phx-value-name={source_type.name}
                disabled={coming_soon}
                class={[
                  "flex flex-col items-center justify-center gap-2 p-4 rounded-xl border-2 transition-all",
                  if(coming_soon,
                    do: "border-base-300 opacity-50 cursor-not-allowed",
                    else: "border-base-300 hover:border-primary hover:bg-primary/5 cursor-pointer"
                  )
                ]}
              >
                <div class="size-10 flex items-center justify-center text-base-content/60">
                  <.source_type_icon source_type={source_type.source_type} />
                </div>
                <span class="text-sm font-medium">{source_type.name}</span>
                <span :if={coming_soon} class="badge badge-xs badge-ghost">Coming Soon</span>
              </button>
            <% end %>
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

          <.form for={@config_form} phx-submit="save_source_config" class="space-y-4">
            <input type="hidden" name="source_id" value={@source.id} />
            <div :for={field <- @config_fields} class="form-control">
              <label class="label"><span class="label-text">{field.label}</span></label>
              <%= if field.type == :textarea do %>
                <textarea
                  name={"config[#{field.key}]"}
                  placeholder={field.placeholder}
                  class="textarea textarea-bordered w-full"
                  rows="4"
                  value={form_value(@config_form, field.key)}
                >{form_value(@config_form, field.key)}</textarea>
              <% else %>
                <input
                  type={if field.type == :password, do: "password", else: "text"}
                  name={"config[#{field.key}]"}
                  placeholder={field.placeholder}
                  value={if field.type != :password, do: form_value(@config_form, field.key)}
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
          </.form>
        </div>
      </div>
    </div>
    """
  end

  # --- Source Type Icon SVGs (shared across setup + chat) ---

  attr :source_type, :string, required: true

  def source_type_icon(%{source_type: "google_drive"} = assigns) do
    ~H"""
    <svg viewBox="0 0 87.3 78" class="size-10" xmlns="http://www.w3.org/2000/svg">
      <path
        d="m6.6 66.85 3.85 6.65c.8 1.4 1.95 2.5 3.3 3.3l13.75-23.8h-27.5c0 1.55.4 3.1 1.2 4.5z"
        fill="#0066da"
      />
      <path
        d="m43.65 25-13.75-23.8c-1.35.8-2.5 1.9-3.3 3.3l-20.4 35.3c-.8 1.4-1.2 2.95-1.2 4.5h27.5z"
        fill="#00ac47"
      />
      <path
        d="m73.55 76.8c1.35-.8 2.5-1.9 3.3-3.3l1.6-2.75 7.65-13.25c.8-1.4 1.2-2.95 1.2-4.5h-27.5l5.85 13.55z"
        fill="#ea4335"
      />
      <path
        d="m43.65 25 13.75-23.8c-1.35-.8-2.9-1.2-4.5-1.2h-18.5c-1.6 0-3.15.45-4.5 1.2z"
        fill="#00832d"
      />
      <path
        d="m59.8 53h-32.3l-13.75 23.8c1.35.8 2.9 1.2 4.5 1.2h50.8c1.6 0 3.15-.45 4.5-1.2z"
        fill="#2684fc"
      />
      <path
        d="m73.4 26.5-10.1-17.5c-.8-1.4-1.95-2.5-3.3-3.3l-13.75 23.8 16.15 23.5h27.45c0-1.55-.4-3.1-1.2-4.5z"
        fill="#ffba00"
      />
    </svg>
    """
  end

  def source_type_icon(%{source_type: "sharepoint"} = assigns) do
    ~H"""
    <svg viewBox="0 0 48 48" class="size-10" xmlns="http://www.w3.org/2000/svg">
      <circle cx="24" cy="18" r="14" fill="#036c70" />
      <circle cx="17" cy="30" r="12" fill="#1a9ba1" />
      <circle cx="24" cy="38" r="10" fill="#37c6d0" />
      <path
        d="M28 8v32c0 1.1-.9 2-2 2H12V10c0-1.1.9-2 2-2h14z"
        fill="white"
        fill-opacity="0.2"
      />
    </svg>
    """
  end

  def source_type_icon(%{source_type: "confluence"} = assigns) do
    ~H"""
    <svg viewBox="0 0 256 246" class="size-10" xmlns="http://www.w3.org/2000/svg">
      <defs>
        <linearGradient id="conf-a" x1="99.14%" y1="34.32%" x2="34.32%" y2="76.39%">
          <stop stop-color="#0052CC" offset="18%" />
          <stop stop-color="#2684FF" offset="100%" />
        </linearGradient>
        <linearGradient id="conf-b" x1="0.86%" y1="65.68%" x2="65.68%" y2="23.61%">
          <stop stop-color="#0052CC" offset="18%" />
          <stop stop-color="#2684FF" offset="100%" />
        </linearGradient>
      </defs>
      <path
        d="M9.26 187.48c-3.7 6.27-7.85 13.6-10.86 19.08a9.27 9.27 0 0 0 3.63 12.75l57.45 30.17a9.34 9.34 0 0 0 12.56-3.09c2.56-4.18 5.8-9.75 9.46-16 24.77-42.2 49.7-37.15 99.57-14.45l56.35 25.6a9.28 9.28 0 0 0 12.37-4.72l26.3-57.77a9.23 9.23 0 0 0-4.47-12.25c-15.2-6.87-45.3-20.47-75.1-34C105.88 93.92 47.65 119.2 9.26 187.48z"
        fill="url(#conf-a)"
      />
      <path
        d="M246.74 58.52c3.7-6.27 7.85-13.6 10.86-19.08a9.27 9.27 0 0 0-3.63-12.75L196.52-3.48a9.34 9.34 0 0 0-12.56 3.09c-2.56 4.18-5.8 9.75-9.46 16-24.77 42.2-49.7 37.15-99.57 14.45L18.58 4.47A9.28 9.28 0 0 0 6.21 9.19l-26.3 57.77a9.23 9.23 0 0 0 4.47 12.25c15.2 6.87 45.3 20.47 75.1 34 90.68 39.88 148.91 14.6 187.26-54.69z"
        fill="url(#conf-b)"
      />
    </svg>
    """
  end

  def source_type_icon(%{source_type: "jira"} = assigns) do
    ~H"""
    <svg viewBox="0 0 256 256" class="size-10" xmlns="http://www.w3.org/2000/svg">
      <defs>
        <linearGradient id="jira-a" x1="98.03%" y1="0.22%" x2="58.89%" y2="40.77%">
          <stop stop-color="#0052CC" offset="18%" />
          <stop stop-color="#2684FF" offset="100%" />
        </linearGradient>
        <linearGradient id="jira-b" x1="100.17%" y1="-.52%" x2="55.42%" y2="44.13%">
          <stop stop-color="#0052CC" offset="18%" />
          <stop stop-color="#2684FF" offset="100%" />
        </linearGradient>
      </defs>
      <path
        d="M244.66 0H121.72a55.34 55.34 0 0 0 55.34 55.34h22.14v21.4a55.34 55.34 0 0 0 55.34 55.34V10.88A10.88 10.88 0 0 0 244.66 0z"
        fill="#2684FF"
      />
      <path
        d="M183.83 61.25H60.89a55.34 55.34 0 0 0 55.34 55.34h22.14v21.4a55.34 55.34 0 0 0 55.34 55.34V72.13a10.88 10.88 0 0 0-9.88-10.88z"
        fill="url(#jira-a)"
      />
      <path
        d="M122.95 122.5H0a55.34 55.34 0 0 0 55.34 55.34h22.14v21.4a55.34 55.34 0 0 0 55.34 55.34V133.38a10.88 10.88 0 0 0-9.87-10.88z"
        fill="url(#jira-b)"
      />
    </svg>
    """
  end

  def source_type_icon(%{source_type: "github"} = assigns) do
    ~H"""
    <svg viewBox="0 0 98 96" class="size-10" xmlns="http://www.w3.org/2000/svg">
      <path
        fill-rule="evenodd"
        clip-rule="evenodd"
        d="M48.854 0C21.839 0 0 22 0 49.217c0 21.756 13.993 40.172 33.405 46.69 2.427.49 3.316-1.059 3.316-2.362 0-1.141-.08-5.052-.08-9.127-13.59 2.934-16.42-5.867-16.42-5.867-2.184-5.704-5.42-7.17-5.42-7.17-4.448-3.015.324-3.015.324-3.015 4.934.326 7.523 5.052 7.523 5.052 4.367 7.496 11.404 5.378 14.235 4.074.404-3.178 1.699-5.378 3.074-6.6-10.839-1.141-22.243-5.378-22.243-24.283 0-5.378 1.94-9.778 5.014-13.2-.485-1.222-2.184-6.275.486-13.038 0 0 4.125-1.304 13.426 5.052a46.97 46.97 0 0 1 12.214-1.63c4.125 0 8.33.571 12.213 1.63 9.302-6.356 13.427-5.052 13.427-5.052 2.67 6.763.97 11.816.485 13.038 3.155 3.422 5.015 7.822 5.015 13.2 0 18.905-11.404 23.06-22.324 24.283 1.78 1.548 3.316 4.481 3.316 9.126 0 6.6-.08 11.897-.08 13.526 0 1.304.89 2.853 3.316 2.364 19.412-6.52 33.405-24.935 33.405-46.691C97.707 22 75.788 0 48.854 0z"
        fill="currentColor"
      />
    </svg>
    """
  end

  def source_type_icon(%{source_type: "gitlab"} = assigns) do
    ~H"""
    <svg viewBox="0 0 380 380" class="size-10" xmlns="http://www.w3.org/2000/svg">
      <path d="m190.41 345.09-68.24-210.07h136.48z" fill="#e24329" />
      <path d="m190.41 345.09-68.24-210.07H18.72z" fill="#fc6d26" />
      <path
        d="M18.72 135.02 3.33 182.35a10.47 10.47 0 0 0 3.81 11.71l183.27 133.03z"
        fill="#fca326"
      />
      <path
        d="M18.72 135.02h103.45L76.05 9.37c-2.39-7.36-12.84-7.36-15.23 0z"
        fill="#e24329"
      />
      <path d="m190.41 345.09 68.24-210.07h103.45z" fill="#fc6d26" />
      <path
        d="M362.1 135.02 377.49 182.35a10.47 10.47 0 0 1-3.81 11.71L190.41 345.09z"
        fill="#fca326"
      />
      <path
        d="M362.1 135.02H258.65l46.12-125.65c2.39-7.36 12.84-7.36 15.23 0z"
        fill="#e24329"
      />
    </svg>
    """
  end

  def source_type_icon(assigns) do
    ~H"""
    <.icon name="hero-folder-micro" class="size-10" />
    """
  end

  # --- Helpers ---

  defp needs_config?(source) do
    if Map.get(source, :builtin, false) do
      false
    else
      source_type = Map.get(source, :source_type)
      required_keys = required_config_keys(source_type)

      if MapSet.size(required_keys) == 0 do
        false
      else
        metadata = Map.get(source, :metadata) || %{}
        present_keys = MapSet.new(Map.keys(metadata))
        not MapSet.subset?(required_keys, present_keys)
      end
    end
  end

  defp required_config_keys(source_type) do
    Liteskill.DataSources.config_fields_for(source_type)
    |> Enum.map(& &1.key)
    |> MapSet.new()
  end

  defp can_delete_source?(source, user) do
    not Map.get(source, :builtin, false) and
      (Map.get(source, :user_id) == user.id or
         Liteskill.Rbac.has_permission?(user.id, "sources:manage_all"))
  end

  defp form_value(form, key) do
    Phoenix.HTML.Form.input_value(form, String.to_existing_atom(key))
  rescue
    ArgumentError -> Phoenix.HTML.Form.input_value(form, key)
  end

  defp source_icon(%{icon: icon}), do: icon
  defp source_icon(_), do: "hero-folder-micro"

  def source_url_id(%{id: "builtin:" <> rest}), do: "builtin-" <> rest
  def source_url_id(%{id: id}), do: id

  defp source_name(%{chunk: %{document: %{source: %{name: name}}}}), do: name
  defp source_name(_), do: nil
end
