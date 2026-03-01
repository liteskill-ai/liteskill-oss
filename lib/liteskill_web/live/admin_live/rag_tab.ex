defmodule LiteskillWeb.AdminLive.RagTab do
  @moduledoc false

  use LiteskillWeb, :html

  import LiteskillWeb.AdminLive.Helpers, only: [require_admin: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Liteskill.LlmModels
  alias Liteskill.Settings

  def assigns do
    [
      rag_embedding_models: [],
      rag_current_model: nil,
      rag_stats: %{},
      rag_confirm_change: false,
      rag_confirm_input: "",
      rag_selected_model_id: nil,
      rag_reembed_in_progress: false
    ]
  end

  def load_data(socket) do
    settings = Settings.get()
    embedding_models = LlmModels.list_all_active_models(model_type: "embedding")
    stats = Liteskill.Rag.Pipeline.public_summary()
    reembed_in_progress = Liteskill.Rag.reembed_in_progress?()

    assign(socket,
      page_title: "RAG Settings",
      server_settings: settings,
      rag_embedding_models: embedding_models,
      rag_current_model: settings.embedding_model,
      rag_stats: stats,
      rag_confirm_change: false,
      rag_confirm_input: "",
      rag_selected_model_id: nil,
      rag_reembed_in_progress: reembed_in_progress
    )
  end

  def handle_event("rag_select_model", %{"model_id" => model_id}, socket) do
    require_admin(socket, fn ->
      current_id =
        case socket.assigns.rag_current_model do
          %{id: id} -> id
          _ -> nil
        end

      selected_id = if model_id == "", do: nil, else: model_id

      if selected_id == current_id do
        {:noreply, put_flash(socket, :info, "Model is already set to this value")}
      else
        {:noreply,
         assign(socket,
           rag_confirm_change: true,
           rag_confirm_input: "",
           rag_selected_model_id: selected_id
         )}
      end
    end)
  end

  def handle_event("rag_cancel_change", _params, socket) do
    {:noreply,
     assign(socket,
       rag_confirm_change: false,
       rag_confirm_input: "",
       rag_selected_model_id: nil
     )}
  end

  def handle_event("rag_confirm_input_change", %{"value" => value}, socket) do
    {:noreply, assign(socket, rag_confirm_input: value)}
  end

  def handle_event("rag_confirm_model_change", %{"confirmation" => confirmation}, socket) do
    require_admin(socket, fn ->
      if confirmation == "I know what this means and I am very sure" do
        selected_id = socket.assigns.rag_selected_model_id
        user_id = socket.assigns.current_user.id

        case Settings.update_embedding_model(selected_id) do
          {:ok, _settings} ->
            Liteskill.Rag.clear_all_embeddings()

            if selected_id do
              %{"user_id" => user_id}
              |> Liteskill.Rag.ReembedWorker.new()
              |> Oban.insert()
            end

            socket =
              socket
              |> load_data()
              |> put_flash(
                :info,
                if(selected_id,
                  do: "Embedding model updated. Re-embedding started.",
                  else: "Embedding model cleared. RAG ingest is now disabled."
                )
              )

            {:noreply, socket}

          {:error, reason} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               action_error("update embedding model", reason)
             )}
        end
      else
        {:noreply, put_flash(socket, :error, "Confirmation text does not match")}
      end
    end)
  end

  def render_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title">Embedding Model</h2>
          <%= if @rag_current_model do %>
            <div class="flex items-center gap-2 mt-2">
              <span class="badge badge-success">Active</span>
              <span class="font-medium">{@rag_current_model.name}</span>
              <span class="text-sm text-base-content/60">({@rag_current_model.model_id})</span>
            </div>
          <% else %>
            <div class="alert alert-warning mt-2">
              <.icon name="hero-exclamation-triangle-micro" class="size-5" />
              <span>No embedding model selected. RAG ingest is disabled.</span>
            </div>
          <% end %>
        </div>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title">Pipeline Stats</h2>
          <div class="stats stats-horizontal shadow mt-2">
            <div class="stat">
              <div class="stat-title">Sources</div>
              <div class="stat-value text-lg">{@rag_stats[:source_count] || 0}</div>
            </div>
            <div class="stat">
              <div class="stat-title">Documents</div>
              <div class="stat-value text-lg">{@rag_stats[:document_count] || 0}</div>
            </div>
            <div class="stat">
              <div class="stat-title">Chunks</div>
              <div class="stat-value text-lg">{@rag_stats[:chunk_count] || 0}</div>
            </div>
          </div>
        </div>
      </div>

      <div :if={@rag_reembed_in_progress} class="alert alert-info">
        <.icon name="hero-arrow-path-micro" class="size-5 animate-spin" />
        <span>Re-embedding is currently in progress. This may take a while.</span>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title">Change Embedding Model</h2>
          <p class="text-sm text-base-content/60 mt-1">
            Changing the model will clear <strong>all existing embeddings</strong>
            and re-generate them using the new model. This is a destructive and
            potentially time-consuming operation.
          </p>

          <%= if @rag_embedding_models == [] do %>
            <div class="alert alert-warning mt-4">
              <.icon name="hero-information-circle-micro" class="size-5" />
              <span>
                No embedding models configured. Add a model with type "embedding"
                in the
                <.link
                  navigate={if @settings_mode, do: ~p"/settings/models", else: ~p"/admin/models"}
                  class="link link-primary"
                >
                  Models
                </.link>
                tab first.
              </span>
            </div>
          <% else %>
            <form phx-submit="rag_select_model" class="flex items-end gap-3 mt-4">
              <div class="form-control flex-1">
                <label class="label"><span class="label-text">Select Model</span></label>
                <select name="model_id" class="select select-bordered w-full">
                  <option value="">-- None (disable RAG) --</option>
                  <option
                    :for={model <- @rag_embedding_models}
                    value={model.id}
                    selected={@rag_current_model && model.id == @rag_current_model.id}
                  >
                    {model.name} ({model.model_id})
                  </option>
                </select>
              </div>
              <button
                type="submit"
                class="btn btn-warning"
                disabled={@rag_reembed_in_progress}
              >
                Change Model
              </button>
            </form>
          <% end %>
        </div>
      </div>

      <%= if @rag_confirm_change do %>
        <div
          class="fixed inset-0 z-50 flex items-center justify-center"
          phx-window-keydown="rag_cancel_change"
          phx-key="Escape"
        >
          <div class="fixed inset-0 bg-black/50" phx-click="rag_cancel_change" />
          <div class="relative bg-base-100 rounded-xl shadow-xl w-full max-w-lg mx-4 z-10">
            <div class="p-6">
              <h3 class="text-lg font-bold text-error flex items-center gap-2">
                <.icon name="hero-exclamation-triangle-micro" class="size-6" /> Dangerous Operation
              </h3>
              <div class="mt-4 space-y-3">
                <p class="text-sm text-base-content/70">
                  This will <strong>permanently clear</strong>
                  all <span class="font-bold text-error">{@rag_stats[:chunk_count] || 0}</span>
                  chunk embeddings across
                  <span class="font-bold">{@rag_stats[:document_count] || 0}</span>
                  documents.
                </p>
                <p class="text-sm text-base-content/70">
                  All RAG search will be unavailable until re-embedding completes.
                  This may take a significant amount of time and will incur API costs.
                </p>
                <p class="text-sm font-medium mt-4">
                  Type the following to confirm:
                </p>
                <code class="block bg-base-200 px-3 py-2 rounded text-sm select-all">
                  I know what this means and I am very sure
                </code>
              </div>
              <form phx-submit="rag_confirm_model_change" class="mt-4">
                <input
                  type="text"
                  name="confirmation"
                  value={@rag_confirm_input}
                  phx-keyup="rag_confirm_input_change"
                  class="input input-bordered w-full"
                  autocomplete="off"
                  placeholder="Type confirmation text..."
                />
                <div class="flex justify-end gap-2 mt-4">
                  <button type="button" phx-click="rag_cancel_change" class="btn btn-ghost">
                    Cancel
                  </button>
                  <button
                    type="submit"
                    class={[
                      "btn btn-error",
                      @rag_confirm_input != "I know what this means and I am very sure" &&
                        "btn-disabled"
                    ]}
                    disabled={@rag_confirm_input != "I know what this means and I am very sure"}
                  >
                    Confirm Change
                  </button>
                </div>
              </form>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
