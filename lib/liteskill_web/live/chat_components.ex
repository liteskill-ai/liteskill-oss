defmodule LiteskillWeb.ChatComponents do
  @moduledoc """
  Core chat function components: messages, conversation list, modals.
  """

  use Phoenix.Component

  import LiteskillWeb.CoreComponents, only: [icon: 1]

  attr :message, :map, required: true

  def message_bubble(assigns) do
    assigns = assign(assigns, :tool_servers, tool_servers_from_message(assigns.message))

    ~H"""
    <%= if @message.role == "user" do %>
      <div class="flex w-full mb-4 justify-end">
        <div class="max-w-[75%]">
          <div class="rounded-2xl rounded-br-sm px-4 py-3 bg-primary text-primary-content">
            <p class="whitespace-pre-wrap break-words text-sm">{@message.content}</p>
          </div>
          <div :if={@tool_servers != []} class="flex flex-wrap gap-1 justify-end mt-1">
            <span
              :for={server <- @tool_servers}
              class="badge badge-xs badge-outline badge-primary gap-1 opacity-70"
            >
              <.icon name="hero-wrench-screwdriver-micro" class="size-2.5" />
              {server["name"]}
            </span>
          </div>
        </div>
      </div>
    <% else %>
      <div class="mb-4 text-base-content">
        <div id={"prose-#{@message.id}"} phx-hook="CopyCode" class="prose prose-sm max-w-none">
          {LiteskillWeb.Markdown.render(@message.content)}
        </div>
      </div>
    <% end %>
    """
  end

  attr :conversation, :map, required: true
  attr :active, :boolean, default: false

  def conversation_item(assigns) do
    ~H"""
    <div class={[
      "group flex items-center gap-1 rounded-lg transition-colors",
      if(@active,
        do: "bg-primary/10 text-primary font-medium",
        else: "hover:bg-base-200 text-base-content"
      )
    ]}>
      <button
        phx-click="select_conversation"
        phx-value-id={@conversation.id}
        class="flex-1 text-left px-3 py-2 text-sm truncate cursor-pointer"
      >
        {@conversation.title}
      </button>
      <button
        phx-click="confirm_delete_conversation"
        phx-value-id={@conversation.id}
        class="opacity-0 group-hover:opacity-100 pr-2 text-base-content/40 hover:text-error transition-opacity cursor-pointer"
      >
        <.icon name="hero-trash-micro" class="size-3.5" />
      </button>
    </div>
    """
  end

  attr :error, :map, required: true

  def stream_error(assigns) do
    ~H"""
    <div class="flex justify-start mb-4">
      <div class="bg-error/10 border border-error/20 rounded-2xl rounded-bl-sm px-4 py-3 max-w-lg">
        <div class="flex items-start gap-2">
          <.icon name="hero-exclamation-triangle-mini" class="size-5 text-error shrink-0 mt-0.5" />
          <div class="flex-1 min-w-0">
            <p class="text-sm font-medium text-error">{@error.title}</p>
            <p class="text-xs text-base-content/60 mt-1">{@error.detail}</p>
            <button
              phx-click="retry_message"
              class="btn btn-error btn-outline btn-xs mt-2"
            >
              <.icon name="hero-arrow-path-micro" class="size-3" /> Retry
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def streaming_indicator(assigns) do
    ~H"""
    <div class="flex justify-start mb-4">
      <div class="bg-base-200 rounded-2xl rounded-bl-sm px-4 py-3">
        <div class="flex gap-1 items-center">
          <span class="w-2 h-2 bg-base-content/40 rounded-full animate-bounce [animation-delay:-0.3s]" />
          <span class="w-2 h-2 bg-base-content/40 rounded-full animate-bounce [animation-delay:-0.15s]" />
          <span class="w-2 h-2 bg-base-content/40 rounded-full animate-bounce" />
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :show, :boolean, required: true
  attr :on_close, :string, required: true
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      :if={@show}
      id={@id}
      class="fixed inset-0 z-50 flex items-center justify-center"
      phx-mounted={@show && Phoenix.LiveView.JS.focus_first(to: "##{@id}-content")}
    >
      <div class="fixed inset-0 bg-black/50" phx-click={@on_close} />
      <div
        id={"#{@id}-content"}
        class="relative bg-base-100 rounded-xl shadow-xl w-full max-w-lg mx-4 max-h-[90vh] overflow-y-auto"
      >
        <div class="flex items-center justify-between p-4 border-b border-base-300">
          <h3 class="text-lg font-semibold">{@title}</h3>
          <button phx-click={@on_close} class="btn btn-ghost btn-sm btn-square">
            <.icon name="hero-x-mark-micro" class="size-5" />
          </button>
        </div>
        <div class="p-4">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  attr :show, :boolean, required: true
  attr :title, :string, required: true
  attr :message, :string, required: true
  attr :confirm_event, :string, required: true
  attr :cancel_event, :string, required: true

  def confirm_modal(assigns) do
    ~H"""
    <div
      :if={@show}
      class="fixed inset-0 z-50 flex items-center justify-center"
      phx-window-keydown={@cancel_event}
      phx-key="Escape"
    >
      <div class="fixed inset-0 bg-black/50" phx-click={@cancel_event} />
      <div class="relative bg-base-100 rounded-xl shadow-xl w-full max-w-sm mx-4 z-10">
        <div class="p-5">
          <h3 class="text-lg font-semibold mb-2">{@title}</h3>
          <p class="text-sm text-base-content/70">{@message}</p>
        </div>
        <div class="flex justify-end gap-2 px-5 pb-5">
          <button phx-click={@cancel_event} class="btn btn-ghost btn-sm">Cancel</button>
          <button phx-click={@confirm_event} class="btn btn-error btn-sm">Archive</button>
        </div>
      </div>
    </div>
    """
  end

  defp tool_servers_from_message(%{tool_config: %{"servers" => servers}}) when is_list(servers),
    do: servers

  defp tool_servers_from_message(_), do: []
end
