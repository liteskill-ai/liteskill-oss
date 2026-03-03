defmodule LiteskillWeb.ChatLive.CostHandler do
  @moduledoc false

  use LiteskillWeb, :html

  alias LiteskillWeb.ChatLive.Helpers, as: ChatHelpers

  def assigns do
    [
      cost_limit: nil,
      cost_limit_input: "",
      cost_limit_tokens: nil,
      show_cost_popover: false,
      show_usage_modal: false,
      usage_modal_data: nil,
      available_llm_models: [],
      selected_llm_model_id: nil
    ]
  end

  @events ~w(select_llm_model toggle_cost_popover update_cost_limit
    clear_cost_limit show_usage_modal close_usage_modal)

  def events, do: @events

  def handle_event("select_llm_model", %{"model_id" => id}, socket) do
    user = socket.assigns.current_user
    Liteskill.Accounts.update_preferences(user, %{"preferred_llm_model_id" => id})

    # Keep cost fixed, recalculate tokens for new model
    tokens =
      if socket.assigns.cost_limit do
        ChatHelpers.estimate_tokens(
          socket.assigns.cost_limit,
          id,
          socket.assigns.available_llm_models
        )
      end

    {:noreply, assign(socket, selected_llm_model_id: id, cost_limit_tokens: tokens)}
  end

  def handle_event("toggle_cost_popover", _params, socket) do
    {:noreply, assign(socket, show_cost_popover: !socket.assigns.show_cost_popover)}
  end

  def handle_event("update_cost_limit", %{"cost" => ""}, socket) do
    {:noreply, assign(socket, cost_limit: nil, cost_limit_input: "", cost_limit_tokens: nil)}
  end

  def handle_event("update_cost_limit", %{"cost" => cost_str} = params, socket) do
    if params["_target"] == ["cost"] do
      case Decimal.parse(cost_str) do
        {cost, _} ->
          tokens =
            ChatHelpers.estimate_tokens(
              cost,
              socket.assigns.selected_llm_model_id,
              socket.assigns.available_llm_models
            )

          {:noreply,
           assign(socket,
             cost_limit: cost,
             cost_limit_input: cost_str,
             cost_limit_tokens: tokens
           )}

        :error ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_cost_limit", %{"tokens" => ""}, socket) do
    {:noreply, assign(socket, cost_limit: nil, cost_limit_input: "", cost_limit_tokens: nil)}
  end

  def handle_event("update_cost_limit", %{"tokens" => tokens_str} = params, socket) do
    if params["_target"] == ["tokens"] do
      case Integer.parse(tokens_str) do
        {tokens, _} when tokens > 0 ->
          cost =
            ChatHelpers.estimate_cost(
              tokens,
              socket.assigns.selected_llm_model_id,
              socket.assigns.available_llm_models
            )

          input_str = if cost, do: Decimal.to_string(Decimal.round(cost, 4)), else: ""

          {:noreply,
           assign(socket,
             cost_limit: cost,
             cost_limit_input: input_str,
             cost_limit_tokens: tokens
           )}

        _ ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("clear_cost_limit", _params, socket) do
    {:noreply,
     assign(socket,
       cost_limit: nil,
       cost_limit_input: "",
       cost_limit_tokens: nil,
       show_cost_popover: false
     )}
  end

  def handle_event("show_usage_modal", _params, socket) do
    conv = socket.assigns.conversation

    if conv do
      totals = Liteskill.Usage.usage_by_conversation(conv.id)

      by_model =
        Liteskill.Usage.usage_summary(conversation_id: conv.id, group_by: :model_id)

      {:noreply,
       assign(socket,
         show_usage_modal: true,
         usage_modal_data: %{totals: totals, by_model: by_model}
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_usage_modal", _params, socket) do
    {:noreply, assign(socket, show_usage_modal: false)}
  end

  # --- Function Components ---

  attr :id, :string, required: true
  attr :class, :string, default: ""
  attr :available_llm_models, :list, required: true
  attr :selected_llm_model_id, :string, default: nil

  def model_picker(assigns) do
    ~H"""
    <div :if={@available_llm_models != []} class={["flex items-center gap-1 px-1", @class]}>
      <.icon name="hero-cpu-chip-micro" class="size-3 text-base-content/40" />
      <form phx-change="select_llm_model">
        <select
          id={@id}
          name="model_id"
          class="select select-ghost select-xs text-xs text-base-content/50 hover:text-base-content/70 min-h-0 h-6 pl-0"
        >
          <%= for m <- @available_llm_models do %>
            <option value={m.id} selected={m.id == @selected_llm_model_id}>
              {m.name}
            </option>
          <% end %>
        </select>
      </form>
    </div>
    """
  end

  attr :cost_limit, :any, default: nil
  attr :cost_limit_input, :string, default: ""
  attr :cost_limit_tokens, :any, default: nil
  attr :show_cost_popover, :boolean, default: false

  def cost_limit_button(assigns) do
    ~H"""
    <div class="relative">
      <button
        type="button"
        phx-click="toggle_cost_popover"
        class={[
          "btn btn-ghost btn-sm btn-square",
          if(@cost_limit, do: "text-warning", else: "text-base-content/50")
        ]}
        title={if @cost_limit, do: "Cost limit: $#{@cost_limit_input}", else: "Set cost limit"}
      >
        <.icon name="hero-currency-dollar-micro" class="size-4" />
      </button>
      <div
        :if={@show_cost_popover}
        class="absolute top-full right-0 mt-1 z-50"
        phx-click-away="toggle_cost_popover"
      >
        <div class="card bg-base-100 shadow-xl border border-base-300 p-3 w-56">
          <h4 class="text-xs font-semibold mb-2">Cost Guardrail</h4>
          <span :if={@cost_limit} class="badge badge-warning badge-sm mb-2">
            ${@cost_limit_input}
            <span :if={@cost_limit_tokens} class="ml-1 opacity-70">
              (~{@cost_limit_tokens} tokens)
            </span>
          </span>
          <form phx-change="update_cost_limit">
            <div class="flex gap-2">
              <div class="form-control flex-1">
                <label class="text-xs text-base-content/60 mb-0.5">Cost ($)</label>
                <input
                  name="cost"
                  type="number"
                  step="0.01"
                  min="0"
                  value={@cost_limit_input}
                  class="input input-xs input-bordered w-full"
                  placeholder="0.50"
                />
              </div>
              <div class="form-control flex-1">
                <label class="text-xs text-base-content/60 mb-0.5">Tokens</label>
                <input
                  name="tokens"
                  type="number"
                  step="1000"
                  min="0"
                  value={@cost_limit_tokens}
                  class="input input-xs input-bordered w-full"
                  placeholder="—"
                />
              </div>
            </div>
          </form>
          <button
            type="button"
            phx-click="clear_cost_limit"
            class="btn btn-ghost btn-xs mt-2 w-full text-base-content/50"
          >
            No limit
          </button>
        </div>
      </div>
    </div>
    """
  end
end
