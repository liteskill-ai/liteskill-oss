defmodule LiteskillWeb.ChatLive do
  @moduledoc false
  use LiteskillWeb, :live_view

  import LiteskillWeb.FormatHelpers, only: [format_cost: 1, format_number: 1]

  alias Liteskill.Chat
  alias Liteskill.Chat.MessageBuilder
  alias Liteskill.Chat.Projector
  alias Liteskill.LLM.RagContext
  alias Liteskill.LLM.StreamHandler
  alias Liteskill.McpServers
  alias LiteskillWeb.ChatComponents
  alias LiteskillWeb.ChatLive.ConversationsHandler
  alias LiteskillWeb.ChatLive.CostHandler
  alias LiteskillWeb.ChatLive.EditHandler
  alias LiteskillWeb.ChatLive.Helpers, as: ChatHelpers
  alias LiteskillWeb.ChatLive.SourcesHandler
  alias LiteskillWeb.ChatLive.ToolHandler
  alias LiteskillWeb.McpComponents
  alias LiteskillWeb.SharingComponents
  alias LiteskillWeb.SharingLive
  alias LiteskillWeb.SourcesComponents

  @impl true
  def mount(_params, _session, socket) do
    conversations = Chat.list_conversations(socket.assigns.current_user.id)

    user = socket.assigns.current_user

    available_llm_models =
      Liteskill.LlmModels.list_active_models(user.id, model_type: "inference")

    preferred_id = get_in(user.preferences, ["preferred_llm_model_id"])
    selected_server_ids = McpServers.load_selected_server_ids(user.id)
    auto_confirm_tools = get_in(user.preferences, ["auto_confirm_tools"]) != false

    selected_llm_model_id =
      cond do
        preferred_id && Enum.any?(available_llm_models, &(&1.id == preferred_id)) ->
          preferred_id

        available_llm_models != [] ->
          hd(available_llm_models).id

        true ->
          nil
      end

    {:ok,
     socket
     |> assign(
       conversations: conversations,
       conversation: nil,
       messages: [],
       form: to_form(%{"content" => ""}, as: :message),
       streaming: false,
       stream_content: "",
       # Tool picker state
       available_tools: [],
       selected_server_ids: selected_server_ids,
       show_tool_picker: false,
       auto_confirm_tools: auto_confirm_tools,
       pending_tool_calls: [],
       tool_call_modal: nil,
       tools_loading: false,
       stream_task_pid: nil,
       sidebar_open: true,
       confirm_delete_id: nil,
       show_sources_sidebar: false,
       sidebar_sources: [],
       show_source_modal: false,
       source_modal_data: %{},
       show_raw_output_modal: false,
       raw_output_message_id: nil,
       raw_output_content: "",
       stream_error: nil,
       # Edit message state
       editing_message_id: nil,
       editing_message_content: "",
       edit_selected_server_ids: MapSet.new(),
       edit_show_tool_picker: false,
       edit_auto_confirm_tools: true,
       # Conversations management view
       managed_conversations: [],
       conversations_page: 1,
       conversations_search: "",
       conversations_total: 0,
       conversations_selected: MapSet.new(),
       conversations_page_size: 20,
       confirm_bulk_delete: false,
       # Sharing modal state
       show_sharing: false,
       sharing_entity_type: nil,
       sharing_entity_id: nil,
       sharing_acls: [],
       sharing_user_search_results: [],
       sharing_user_search_query: "",
       sharing_groups: [],
       sharing_error: nil,
       # LLM model selection
       available_llm_models: available_llm_models,
       selected_llm_model_id: selected_llm_model_id,
       # Cost guardrail
       cost_limit: nil,
       cost_limit_input: "",
       cost_limit_tokens: nil,
       show_cost_popover: false,
       # Conversation usage modal
       show_usage_modal: false,
       usage_modal_data: nil,
       has_admin_access: Liteskill.Rbac.has_any_admin_permission?(user.id),
       single_user_mode: Liteskill.SingleUser.enabled?()
     )
     |> then(fn socket ->
       if MapSet.size(selected_server_ids) > 0, do: send(self(), :fetch_tools)
       socket
     end), layout: {LiteskillWeb.Layouts, :chat}}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if socket.assigns.current_user.force_password_change &&
         socket.assigns.live_action != :password do
      {:noreply, push_navigate(socket, to: ~p"/profile/password")}
    else
      {:noreply,
       socket
       |> assign(show_raw_output_modal: false, raw_output_message_id: nil, raw_output_content: "")
       |> push_event("nav", %{})
       |> push_accent_color()
       |> apply_action(socket.assigns.live_action, params)}
    end
  end

  defp push_accent_color(socket) do
    color = Liteskill.Accounts.User.accent_color(socket.assigns.current_user)
    push_event(socket, "set-accent", %{color: color})
  end

  defp apply_action(socket, :index, _params) do
    # Unsubscribe from previous conversation if any
    maybe_unsubscribe(socket)

    assign(socket,
      conversation: nil,
      messages: [],
      streaming: false,
      stream_content: "",
      pending_tool_calls: [],
      page_title: "Liteskill"
    )
  end

  defp apply_action(socket, :conversations, _params) do
    maybe_unsubscribe(socket)
    user_id = socket.assigns.current_user.id
    page_size = socket.assigns.conversations_page_size

    managed = Chat.list_conversations(user_id, limit: page_size, offset: 0)
    total = Chat.count_conversations(user_id)

    assign(socket,
      conversation: nil,
      messages: [],
      streaming: false,
      stream_content: "",
      pending_tool_calls: [],
      managed_conversations: managed,
      conversations_page: 1,
      conversations_search: "",
      conversations_total: total,
      conversations_selected: MapSet.new(),
      confirm_bulk_delete: false,
      page_title: "Conversations"
    )
  end

  defp apply_action(socket, :show, params) do
    conversation_id = params["conversation_id"]
    auto_stream = params["auto_stream"] == "1"
    user_id = socket.assigns.current_user.id

    # Unsubscribe from previous conversation
    maybe_unsubscribe(socket)

    case Chat.get_conversation(conversation_id, user_id) do
      {:ok, conversation} ->
        # Subscribe to PubSub for real-time updates
        topic = "event_store:#{conversation.stream_id}"
        Phoenix.PubSub.subscribe(Liteskill.PubSub, topic)

        # If conversation is stuck in streaming but we have no active task, recover it
        {conversation, streaming} =
          if conversation.status == "streaming" && socket.assigns.stream_task_pid == nil do
            Chat.recover_stream(conversation_id, user_id)
            Projector.sync()
            {:ok, recovered} = Chat.get_conversation(conversation_id, user_id)
            {recovered, false}
          else
            {conversation, conversation.status == "streaming"}
          end

        pending =
          if streaming, do: ToolHandler.load_pending_tool_calls(conversation.messages), else: []

        socket =
          assign(socket,
            conversation: conversation,
            messages: conversation.messages,
            streaming: streaming,
            stream_content: "",
            pending_tool_calls: pending,
            page_title: conversation.title
          )

        # Auto-start stream after navigation from new conversation creation
        if auto_stream && !streaming do
          last_user_msg =
            conversation.messages
            |> Enum.filter(&(&1.role == "user"))
            |> List.last()

          tool_config = if last_user_msg, do: last_user_msg.tool_config
          pid = trigger_llm_stream(conversation, user_id, socket, tool_config)

          assign(socket,
            streaming: true,
            stream_content: "",
            stream_error: nil,
            pending_tool_calls: [],
            stream_task_pid: pid
          )
        else
          socket
        end

      {:error, reason} ->
        socket
        |> put_flash(:error, action_error("load conversation", reason))
        |> push_navigate(to: ~p"/")
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:show_raw_output_modal, fn -> false end)
      |> assign_new(:raw_output_message_id, fn -> nil end)
      |> assign_new(:raw_output_content, fn -> "" end)

    ~H"""
    <div class="flex h-screen relative">
      <Layouts.sidebar
        sidebar_open={@sidebar_open}
        live_action={@live_action}
        conversations={@conversations}
        active_conversation_id={@conversation && @conversation.id}
        current_user={@current_user}
        has_admin_access={@has_admin_access}
        single_user_mode={@single_user_mode}
      />

      <%!-- Main Area --%>
      <main class="flex-1 flex flex-col min-w-0">
        <%= if @live_action == :conversations do %>
          <div class="flex-1 flex flex-col min-w-0">
            <header class="px-4 py-3 border-b border-base-300 flex-shrink-0">
              <div class="flex items-center justify-between">
                <div class="flex items-center gap-2">
                  <button
                    :if={!@sidebar_open}
                    phx-click="toggle_sidebar"
                    class="btn btn-circle btn-ghost btn-sm"
                  >
                    <.icon name="hero-bars-3-micro" class="size-5" />
                  </button>
                  <h1 class="text-lg font-semibold">Conversations</h1>
                  <span class="text-sm text-base-content/50">
                    ({@conversations_total})
                  </span>
                </div>
                <div class="flex items-center gap-2">
                  <button
                    :if={MapSet.size(@conversations_selected) > 0}
                    phx-click="confirm_bulk_archive"
                    class="btn btn-error btn-sm gap-1"
                  >
                    <.icon name="hero-trash-micro" class="size-4" />
                    Archive ({MapSet.size(@conversations_selected)})
                  </button>
                </div>
              </div>
            </header>

            <div class="p-4 border-b border-base-300">
              <form phx-change="conversations_search" phx-submit="conversations_search">
                <input
                  type="text"
                  name="search"
                  value={@conversations_search}
                  placeholder="Search conversations..."
                  class="input input-bordered input-sm w-full max-w-sm"
                  phx-debounce="300"
                  autocomplete="off"
                />
              </form>
            </div>

            <div class="flex-1 overflow-y-auto">
              <div :if={@managed_conversations != []} class="divide-y divide-base-200">
                <div class="flex items-center gap-3 px-4 py-2 bg-base-200/50 text-xs text-base-content/60 sticky top-0">
                  <input
                    type="checkbox"
                    class="checkbox checkbox-sm checkbox-primary"
                    checked={
                      MapSet.size(@conversations_selected) == length(@managed_conversations) and
                        @managed_conversations != []
                    }
                    phx-click="toggle_select_all_conversations"
                  />
                  <span>Select all</span>
                </div>
                <div
                  :for={conv <- @managed_conversations}
                  class={[
                    "flex items-center gap-3 px-4 py-3 hover:bg-base-200/50 transition-colors",
                    MapSet.member?(@conversations_selected, conv.id) && "bg-primary/5"
                  ]}
                >
                  <input
                    type="checkbox"
                    class="checkbox checkbox-sm checkbox-primary"
                    checked={MapSet.member?(@conversations_selected, conv.id)}
                    phx-click="toggle_select_conversation"
                    phx-value-id={conv.id}
                  />
                  <.link navigate={~p"/c/#{conv.id}"} class="flex-1 min-w-0">
                    <p class="text-sm font-medium truncate">{conv.title}</p>
                    <p class="text-xs text-base-content/50">
                      {Calendar.strftime(conv.updated_at, "%b %d, %Y %H:%M")} · {conv.message_count ||
                        0} messages
                    </p>
                  </.link>
                  <button
                    phx-click="confirm_delete_conversation"
                    phx-value-id={conv.id}
                    class="btn btn-ghost btn-xs text-base-content/40 hover:text-error"
                  >
                    <.icon name="hero-trash-micro" class="size-3.5" />
                  </button>
                </div>
              </div>

              <p
                :if={@managed_conversations == []}
                class="text-base-content/50 text-center py-12"
              >
                {if @conversations_search != "",
                  do: "No conversations match your search.",
                  else: "No conversations yet."}
              </p>

              <div
                :if={@conversations_total > @conversations_page_size}
                class="flex justify-center items-center gap-2 py-4 border-t border-base-200"
              >
                <button
                  :if={@conversations_page > 1}
                  phx-click="conversations_page"
                  phx-value-page={@conversations_page - 1}
                  class="btn btn-ghost btn-sm"
                >
                  Previous
                </button>
                <span class="text-sm text-base-content/60">
                  Page {@conversations_page} of {ceil(@conversations_total / @conversations_page_size)}
                </span>
                <button
                  :if={@conversations_page * @conversations_page_size < @conversations_total}
                  phx-click="conversations_page"
                  phx-value-page={@conversations_page + 1}
                  class="btn btn-ghost btn-sm"
                >
                  Next
                </button>
              </div>
            </div>
          </div>

          <ChatComponents.confirm_modal
            show={@confirm_bulk_delete}
            title="Archive conversations"
            message={"Are you sure you want to archive #{MapSet.size(@conversations_selected)} conversation(s)?"}
            confirm_event="bulk_archive_conversations"
            cancel_event="cancel_bulk_archive"
            confirm_label="Archive"
          />
        <% end %>
        <%= if @live_action not in [:conversations] do %>
          <%= if @conversation do %>
            <%!-- Active conversation --%>
            <div class="flex flex-1 min-w-0 overflow-hidden">
              <div class="flex-1 flex flex-col min-w-0">
                <header class="px-4 py-3 border-b border-base-300 flex-shrink-0">
                  <div class="flex items-center gap-2">
                    <button
                      :if={!@sidebar_open}
                      phx-click="toggle_sidebar"
                      class="btn btn-circle btn-ghost btn-sm"
                    >
                      <.icon name="hero-bars-3-micro" class="size-5" />
                    </button>
                    <h1 class="text-lg font-semibold truncate flex-1">{@conversation.title}</h1>
                    <CostHandler.cost_limit_button
                      cost_limit={@cost_limit}
                      cost_limit_input={@cost_limit_input}
                      cost_limit_tokens={@cost_limit_tokens}
                      show_cost_popover={@show_cost_popover}
                    />
                    <button
                      phx-click="show_usage_modal"
                      class="btn btn-ghost btn-sm btn-square"
                      title="Usage info"
                    >
                      <.icon name="hero-information-circle-micro" class="size-4" />
                    </button>
                    <button
                      phx-click="open_sharing"
                      phx-value-entity-type="conversation"
                      phx-value-entity-id={@conversation.id}
                      class="btn btn-ghost btn-sm btn-square"
                      title="Share"
                    >
                      <.icon name="hero-share-micro" class="size-4" />
                    </button>
                  </div>
                </header>

                <div id="messages" phx-hook="ScrollBottom" class="flex-1 overflow-y-auto px-4 py-4">
                  <%= for msg <- ChatHelpers.display_messages(@messages, @editing_message_id) do %>
                    <ChatComponents.message_bubble
                      :if={msg.content && msg.content != ""}
                      message={msg}
                      can_edit={msg.role == "user" && !@streaming && @editing_message_id == nil}
                      editing={@editing_message_id == msg.id}
                      editing_content={@editing_message_content}
                      available_tools={@available_tools}
                      edit_selected_server_ids={@edit_selected_server_ids}
                      edit_show_tool_picker={@edit_show_tool_picker}
                      edit_auto_confirm={@edit_auto_confirm_tools}
                    />
                    <SourcesComponents.sources_button
                      :if={@editing_message_id != msg.id}
                      message={msg}
                    />
                    <%!-- Tool calls for completed messages (inline) --%>
                    <%= if msg.role == "assistant" && msg.stop_reason == "tool_use" do %>
                      <%= for tc <- MessageBuilder.tool_calls_for_message(msg) do %>
                        <McpComponents.tool_call_display
                          tool_call={tc}
                          show_actions={!@auto_confirm_tools && tc.status == "started"}
                        />
                      <% end %>
                    <% end %>
                    <ChatComponents.stream_error
                      :if={msg.status == "failed" && msg == List.last(@messages) && !@stream_error}
                      error={
                        %{
                          title: "The AI service was unavailable",
                          detail: "The response failed to generate. Click retry to try again."
                        }
                      }
                    />
                  <% end %>
                  <div :if={@streaming && @stream_content != ""} class="mb-4 text-base-content">
                    <div id="streaming-prose" phx-hook="CopyCode" class="prose prose-sm max-w-none">
                      {LiteskillWeb.Markdown.render_streaming(@stream_content)}
                    </div>
                  </div>
                  <ChatComponents.streaming_indicator :if={@streaming && @stream_content == ""} />
                  <%!-- Pending tool calls from streaming message (rendered from socket state, not DB) --%>
                  <%= for tc <- @pending_tool_calls do %>
                    <McpComponents.tool_call_display
                      tool_call={tc}
                      show_actions={!@auto_confirm_tools && tc.status == "started"}
                    />
                  <% end %>
                  <ChatComponents.stream_error :if={@stream_error} error={@stream_error} />
                </div>

                <div class="flex-shrink-0 border-t border-base-300 px-4 py-3">
                  <div class="flex items-center gap-2 mb-1">
                    <McpComponents.selected_server_badges
                      available_tools={@available_tools}
                      selected_server_ids={@selected_server_ids}
                    />
                  </div>
                  <.form
                    for={@form}
                    phx-submit="send_message"
                    phx-change="form_changed"
                    class="flex items-center gap-0 border border-base-300 rounded-xl bg-base-100 focus-within:border-primary/50 transition-colors"
                  >
                    <McpComponents.server_picker
                      available_tools={@available_tools}
                      selected_server_ids={@selected_server_ids}
                      show={@show_tool_picker}
                      auto_confirm={@auto_confirm_tools}
                      tools_loading={@tools_loading}
                    />
                    <textarea
                      id="message-input"
                      name="message[content]"
                      phx-hook="TextareaAutoResize"
                      placeholder="Type a message..."
                      rows="1"
                      class="flex-1 bg-transparent border-0 focus:outline-none focus:ring-0 resize-none min-h-[2.5rem] max-h-40 py-2 px-1 text-base-content placeholder:text-base-content/40"
                      disabled={@streaming}
                    >{Phoenix.HTML.Form.input_value(@form, :content)}</textarea>
                    <button
                      :if={!@streaming}
                      type="submit"
                      class="btn btn-ghost btn-sm text-primary hover:bg-primary/10 m-1"
                    >
                      <.icon name="hero-paper-airplane-micro" class="size-5" />
                    </button>
                    <button
                      :if={@streaming}
                      type="button"
                      phx-click="cancel_stream"
                      class="btn btn-ghost btn-sm text-error hover:bg-error/10 m-1"
                    >
                      <.icon name="hero-stop-micro" class="size-5" />
                    </button>
                  </.form>
                  <CostHandler.model_picker
                    id="model-picker-conversation"
                    class="mt-1"
                    available_llm_models={@available_llm_models}
                    selected_llm_model_id={@selected_llm_model_id}
                  />
                </div>
              </div>
              <SourcesComponents.sources_sidebar
                show={@show_sources_sidebar}
                sources={@sidebar_sources}
              />
            </div>
          <% else %>
            <%!-- New conversation prompt --%>
            <div :if={!@sidebar_open} class="px-4 pt-3">
              <button phx-click="toggle_sidebar" class="btn btn-circle btn-ghost btn-sm">
                <.icon name="hero-bars-3-micro" class="size-5" />
              </button>
            </div>
            <div class="flex-1 flex items-center justify-center px-4">
              <div class="w-full max-w-xl text-center">
                <h1 class="text-3xl font-bold mb-8 text-base-content">
                  What can I help you with?
                </h1>
                <McpComponents.selected_server_badges
                  available_tools={@available_tools}
                  selected_server_ids={@selected_server_ids}
                />
                <.form
                  for={@form}
                  phx-submit="send_message"
                  phx-change="form_changed"
                  class="flex items-center gap-0 border border-base-300 rounded-xl bg-base-100 focus-within:border-primary/50 transition-colors"
                >
                  <McpComponents.server_picker
                    available_tools={@available_tools}
                    selected_server_ids={@selected_server_ids}
                    show={@show_tool_picker}
                    auto_confirm={@auto_confirm_tools}
                    tools_loading={@tools_loading}
                  />
                  <textarea
                    id="message-input"
                    name="message[content]"
                    phx-hook="TextareaAutoResize"
                    placeholder="Type a message..."
                    rows="1"
                    class="flex-1 bg-transparent border-0 focus:outline-none focus:ring-0 resize-none min-h-[2.5rem] max-h-40 py-2 px-1 text-base-content placeholder:text-base-content/40"
                  >{Phoenix.HTML.Form.input_value(@form, :content)}</textarea>
                  <button
                    type="submit"
                    class="btn btn-ghost btn-sm text-primary hover:bg-primary/10 m-1"
                  >
                    <.icon name="hero-paper-airplane-micro" class="size-5" />
                  </button>
                </.form>
                <div class="flex items-center justify-center gap-2 mt-2">
                  <CostHandler.model_picker
                    id="model-picker-new"
                    available_llm_models={@available_llm_models}
                    selected_llm_model_id={@selected_llm_model_id}
                  />
                  <CostHandler.cost_limit_button
                    cost_limit={@cost_limit}
                    cost_limit_input={@cost_limit_input}
                    cost_limit_tokens={@cost_limit_tokens}
                    show_cost_popover={@show_cost_popover}
                  />
                </div>
                <p
                  :if={@available_llm_models == []}
                  class="text-sm text-warning mt-2 px-1"
                >
                  No models configured.
                  <.link navigate={~p"/admin/models"} class="link link-primary">
                    Add one in Settings
                  </.link>
                </p>
              </div>
            </div>
          <% end %>
        <% end %>
      </main>

      <SourcesComponents.source_detail_modal
        show={@show_source_modal}
        source={@source_modal_data}
      />
      <SourcesComponents.raw_output_modal
        show={@show_raw_output_modal}
        raw_output={@raw_output_content}
        message_id={@raw_output_message_id}
      />

      <ChatComponents.confirm_modal
        show={@confirm_delete_id != nil}
        title="Archive conversation"
        message="Are you sure you want to archive this conversation?"
        confirm_event="delete_conversation"
        cancel_event="cancel_delete_conversation"
        confirm_label="Archive"
      />

      <McpComponents.tool_call_modal tool_call={@tool_call_modal} />

      <SharingComponents.sharing_modal
        show={@show_sharing}
        entity_type={@sharing_entity_type || "conversation"}
        entity_id={@sharing_entity_id}
        acls={@sharing_acls}
        user_search_results={@sharing_user_search_results}
        user_search_query={@sharing_user_search_query}
        groups={@sharing_groups}
        current_user_id={@current_user.id}
        error={@sharing_error}
      />

      <ChatComponents.modal
        id="usage-modal"
        title="Conversation Usage"
        show={@show_usage_modal}
        on_close="close_usage_modal"
      >
        <div :if={@usage_modal_data} class="space-y-4">
          <div class="grid grid-cols-3 gap-3">
            <div class="text-center p-3 bg-base-200 rounded-lg">
              <div class="text-xs text-base-content/60">Input Cost</div>
              <div class="text-lg font-bold">
                {format_cost(@usage_modal_data.totals.input_cost)}
              </div>
            </div>
            <div class="text-center p-3 bg-base-200 rounded-lg">
              <div class="text-xs text-base-content/60">Output Cost</div>
              <div class="text-lg font-bold">
                {format_cost(@usage_modal_data.totals.output_cost)}
              </div>
            </div>
            <div class="text-center p-3 bg-base-200 rounded-lg">
              <div class="text-xs text-base-content/60">Total Cost</div>
              <div class="text-lg font-bold">
                {format_cost(@usage_modal_data.totals.total_cost)}
              </div>
            </div>
          </div>

          <div class="text-sm text-base-content/60 grid grid-cols-3 gap-3">
            <div class="text-center">
              <span class="font-mono">
                {format_number(@usage_modal_data.totals.input_tokens)}
              </span>
              <span class="ml-1">in</span>
            </div>
            <div class="text-center">
              <span class="font-mono">
                {format_number(@usage_modal_data.totals.output_tokens)}
              </span>
              <span class="ml-1">out</span>
            </div>
            <div class="text-center">
              <span class="font-mono">
                {format_number(@usage_modal_data.totals.total_tokens)}
              </span>
              <span class="ml-1">total</span>
            </div>
          </div>

          <div :if={@usage_modal_data.by_model != []} class="divider my-2">By Model</div>

          <div :if={@usage_modal_data.by_model != []} class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Model</th>
                  <th class="text-right">In Cost</th>
                  <th class="text-right">Out Cost</th>
                  <th class="text-right">Total</th>
                  <th class="text-right">Calls</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @usage_modal_data.by_model}>
                  <td class="font-mono text-xs max-w-[200px] truncate">{row.model_id}</td>
                  <td class="text-right">{format_cost(row.input_cost)}</td>
                  <td class="text-right">{format_cost(row.output_cost)}</td>
                  <td class="text-right">{format_cost(row.total_cost)}</td>
                  <td class="text-right">{row.call_count}</td>
                </tr>
              </tbody>
            </table>
          </div>

          <p
            :if={@usage_modal_data.by_model == [] && @usage_modal_data.totals.call_count == 0}
            class="text-center text-base-content/50 py-4"
          >
            No usage data for this conversation yet.
          </p>
        </div>
      </ChatComponents.modal>
    </div>
    """
  end

  # --- Events ---

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, sidebar_open: !socket.assigns.sidebar_open)}
  end

  @impl true
  def handle_event("close_sidebar", _params, socket) do
    {:noreply, assign(socket, sidebar_open: false)}
  end

  # --- Sources Sidebar Events ---

  @sources_events SourcesHandler.events()

  @impl true
  def handle_event(event, params, socket) when event in @sources_events do
    SourcesHandler.handle_event(event, params, socket)
  end

  @impl true
  def handle_event("select_conversation", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/c/#{id}")}
  end

  @impl true
  def handle_event("form_changed", %{"message" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: :message))}
  end

  @impl true
  def handle_event("send_message", %{"message" => %{"content" => content}}, socket) do
    content = String.trim(content)

    cond do
      content == "" ->
        {:noreply, socket}

      socket.assigns.available_llm_models == [] ->
        {:noreply, put_flash(socket, :error, "No models configured. Add one in Settings > Models.")}

      true ->
        user_id = socket.assigns.current_user.id
        tool_config = ToolHandler.build_tool_config(socket)

        case socket.assigns.conversation do
          nil ->
            create_params = %{
              user_id: user_id,
              title: ChatHelpers.truncate_title(content),
              llm_model_id: socket.assigns.selected_llm_model_id
            }

            case Chat.create_conversation(create_params) do
              {:ok, conversation} ->
                case Chat.send_message(conversation.id, user_id, content, tool_config: tool_config) do
                  {:ok, _message} ->
                    {:noreply, push_navigate(socket, to: "/c/#{conversation.id}?auto_stream=1")}

                  {:error, reason} ->
                    {:noreply, put_flash(socket, :error, action_error("send message", reason))}
                end

              {:error, reason} ->
                {:noreply, put_flash(socket, :error, action_error("create conversation", reason))}
            end

          conversation ->
            case Chat.send_message(conversation.id, user_id, content, tool_config: tool_config) do
              {:ok, _message} ->
                {:ok, messages} = Chat.list_messages(conversation.id, user_id)
                pid = trigger_llm_stream(conversation, user_id, socket, tool_config)

                {:noreply,
                 assign(socket,
                   messages: messages,
                   form: to_form(%{"content" => ""}, as: :message),
                   streaming: true,
                   stream_content: "",
                   stream_error: nil,
                   pending_tool_calls: [],
                   stream_task_pid: pid
                 )}

              {:error, reason} ->
                {:noreply, put_flash(socket, :error, action_error("send message", reason))}
            end
        end
    end
  end

  # --- Conversations Management Events ---

  @conversations_events ConversationsHandler.events()

  @impl true
  def handle_event(event, params, socket) when event in @conversations_events do
    ConversationsHandler.handle_event(event, params, socket)
  end

  @impl true
  def handle_event("cancel_stream", _params, socket) do
    # Kill the streaming task to stop token burn immediately
    if pid = socket.assigns.stream_task_pid do
      Process.exit(pid, :shutdown)
    end

    {:noreply, recover_stuck_stream(socket)}
  end

  @impl true
  def handle_event("retry_message", _params, socket) do
    conversation = socket.assigns.conversation
    user_id = socket.assigns.current_user.id

    if conversation do
      # Use tool config from the last user message (if any) for retry
      last_user_msg =
        socket.assigns.messages
        |> Enum.filter(&(&1.role == "user"))
        |> List.last()

      tool_config = if last_user_msg, do: last_user_msg.tool_config
      pid = trigger_llm_stream(conversation, user_id, socket, tool_config)

      {:noreply,
       assign(socket,
         streaming: true,
         stream_content: "",
         stream_error: nil,
         pending_tool_calls: [],
         stream_task_pid: pid
       )}
    else
      {:noreply, socket}
    end
  end

  # --- Edit Message Events ---

  @edit_events EditHandler.events()

  @impl true
  def handle_event(event, params, socket) when event in @edit_events do
    EditHandler.handle_event(event, params, socket)
  end

  @impl true
  def handle_event("confirm_edit", params, socket) do
    case EditHandler.handle_confirm_edit(params, socket) do
      {:stream, socket, conversation, tool_config} ->
        pid =
          trigger_llm_stream(conversation, socket.assigns.current_user.id, socket, tool_config)

        {:noreply,
         assign(socket,
           streaming: true,
           stream_content: "",
           stream_error: nil,
           pending_tool_calls: [],
           stream_task_pid: pid
         )}

      {:noreply, socket} ->
        {:noreply, socket}
    end
  end

  # --- Cost / Model / Usage Events ---

  @cost_events CostHandler.events()

  @impl true
  def handle_event(event, params, socket) when event in @cost_events do
    CostHandler.handle_event(event, params, socket)
  end

  # --- Tool Picker Events ---

  @tool_events ToolHandler.events()

  @impl true
  def handle_event(event, params, socket) when event in @tool_events do
    ToolHandler.handle_event(event, params, socket)
  end

  # --- Sharing Modal Events ---

  @sharing_events SharingLive.sharing_events()

  @impl true
  def handle_event(event, params, socket) when event in @sharing_events do
    SharingLive.handle_event(event, params, socket)
  end

  # --- PubSub Handlers ---

  @impl true
  def handle_info({:events, _stream_id, events}, socket) do
    socket = Enum.reduce(events, socket, &handle_event_store_event/2)
    {:noreply, socket}
  end

  def handle_info(:reload_after_complete, socket) do
    case socket.assigns.conversation do
      nil ->
        {:noreply, socket}

      conversation ->
        user_id = socket.assigns.current_user.id

        {:ok, messages} = Chat.list_messages(conversation.id, user_id)
        conversations = Chat.list_conversations(user_id)

        # Reload conversation to check actual status — avoids race when
        # StreamHandler immediately starts a new round after completing
        {:ok, fresh_conv} = Chat.get_conversation(conversation.id, user_id)

        # The stream task runs the entire multi-round loop (including tool calls).
        # Between rounds the DB status is "active", but the task is still working.
        # Keep the typing indicator alive while the task process is running.
        task_alive = task_alive?(socket.assigns.stream_task_pid)
        still_streaming = fresh_conv.status == "streaming" || task_alive

        # Preserve stream_content only when actually mid-stream (DB says "streaming").
        # Between rounds (task alive, DB "active") clear it so the typing indicator shows
        # and the already-committed text doesn't duplicate the DB messages.
        db_streaming = fresh_conv.status == "streaming"

        {:noreply,
         assign(socket,
           streaming: still_streaming,
           stream_content: if(db_streaming, do: socket.assigns.stream_content, else: ""),
           messages: messages,
           conversations: conversations,
           conversation: fresh_conv,
           pending_tool_calls: if(task_alive && db_streaming, do: socket.assigns.pending_tool_calls, else: []),
           stream_task_pid: if(still_streaming, do: socket.assigns.stream_task_pid)
         )}
    end
  end

  def handle_info(:fetch_tools, socket), do: ToolHandler.handle_info(:fetch_tools, socket)

  def handle_info(:reload_tool_calls, socket), do: ToolHandler.handle_info(:reload_tool_calls, socket)

  def handle_info({:DOWN, _ref, :process, pid, _reason}, socket) do
    if socket.assigns.streaming && pid == socket.assigns.stream_task_pid do
      {:noreply, recover_stuck_stream(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp handle_event_store_event(%{event_type: "AssistantStreamStarted"}, socket) do
    # Clear pending_tool_calls — previous round's tool calls are now in the DB
    # and rendered inline on their parent message.
    assign(socket,
      streaming: true,
      stream_content: "",
      stream_error: nil,
      pending_tool_calls: []
    )
  end

  defp handle_event_store_event(%{event_type: "AssistantChunkReceived", data: data}, socket) do
    delta = data["delta_text"] || ""
    assign(socket, stream_content: socket.assigns.stream_content <> delta)
  end

  defp handle_event_store_event(%{event_type: "AssistantStreamCompleted"}, socket) do
    # Delay reload to let the Projector finish updating the DB.
    # Keep streaming content visible until then.
    Process.send_after(self(), :reload_after_complete, 100)
    socket
  end

  defp handle_event_store_event(%{event_type: "AssistantStreamFailed", data: data}, socket) do
    error = ChatHelpers.friendly_stream_error(data["error_type"], data["error_message"])

    assign(socket, streaming: false, stream_content: "", stream_error: error)
  end

  defp handle_event_store_event(%{event_type: "UserMessageAdded"}, socket) do
    # Reload messages (handles shared conversations)
    user_id = socket.assigns.current_user.id
    conversation = socket.assigns.conversation
    {:ok, messages} = Chat.list_messages(conversation.id, user_id)
    assign(socket, messages: messages)
  end

  defp handle_event_store_event(%{event_type: "ToolCallStarted", data: data}, socket) do
    # Build tool call immediately from event data to avoid race with projector
    tc = ToolHandler.build_tool_call_from_event(data)

    pending = socket.assigns.pending_tool_calls ++ [tc]

    # Also schedule a DB reload to sync fully
    Process.send_after(self(), :reload_tool_calls, 500)
    assign(socket, pending_tool_calls: pending)
  end

  defp handle_event_store_event(%{event_type: "ToolCallCompleted", data: data}, socket) do
    # Update the pending tool call status immediately
    tool_use_id = data["tool_use_id"]

    pending =
      Enum.map(socket.assigns.pending_tool_calls, fn tc ->
        if tc.tool_use_id == tool_use_id do
          %{tc | status: "completed", output: data["output"]}
        else
          tc
        end
      end)

    # Also schedule a DB reload to sync fully
    Process.send_after(self(), :reload_tool_calls, 500)
    assign(socket, pending_tool_calls: pending)
  end

  defp handle_event_store_event(_event, socket), do: socket

  # --- Helpers ---

  defp trigger_llm_stream(conversation, user_id, socket, tool_config) do
    {:ok, messages} = Chat.list_messages(conversation.id, user_id)

    tool_opts =
      if tool_config do
        ToolHandler.build_tool_opts_from_config(tool_config, user_id)
      else
        ToolHandler.build_tool_opts(socket)
      end

    has_tools = Keyword.has_key?(tool_opts, :tools)

    llm_messages = MessageBuilder.build_llm_messages(messages)
    # Strip toolUse/toolResult blocks when no tools are selected — Bedrock
    # returns 400 if messages contain toolUse but no tools config is provided.
    llm_messages =
      if has_tools, do: llm_messages, else: MessageBuilder.strip_tool_blocks(llm_messages)

    # RAG context augmentation
    last_user_msg = messages |> Enum.filter(&(&1.role == "user")) |> List.last()
    query = if last_user_msg, do: last_user_msg.content

    {rag_results, rag_sources_json} =
      if query && String.trim(query) != "" do
        case Liteskill.Rag.augment_context(query, user_id) do
          {:ok, results} when results != [] ->
            {results, RagContext.serialize_sources(results)}

          _ ->
            {[], nil}
        end
      else
        {[], nil}
      end

    system_prompt =
      RagContext.build_system_prompt(rag_results, conversation.system_prompt)

    opts = if system_prompt, do: [system: system_prompt], else: []

    # Always pass user_id and conversation_id for usage tracking
    opts = [{:user_id, user_id}, {:conversation_id, conversation.id} | opts]

    # Cost guardrail
    opts =
      if socket.assigns.cost_limit do
        [{:cost_limit, socket.assigns.cost_limit} | opts]
      else
        opts
      end

    # Add tool options if tools are selected
    opts = opts ++ tool_opts

    # Pass rag_sources through the event store so they survive navigation
    opts = if rag_sources_json, do: [{:rag_sources, rag_sources_json} | opts], else: opts

    # Load LLM model config from UI-selected model
    opts =
      case socket.assigns[:selected_llm_model_id] do
        nil ->
          opts

        model_id ->
          case Liteskill.LlmModels.get_model(model_id, user_id) do
            {:ok, llm_model} -> [{:llm_model, llm_model} | opts]
            _ -> opts
          end
      end

    # Strip tools if model doesn't support them (e.g. Llama models on Bedrock)
    # Admins set {"supports_tools": false} in model config.
    {opts, llm_messages} =
      case Keyword.get(opts, :llm_model) do
        %{model_config: %{"supports_tools" => false}} ->
          stripped_opts = Keyword.drop(opts, [:tools, :tool_servers, :auto_confirm])
          {stripped_opts, MessageBuilder.strip_tool_blocks(llm_messages)}

        _ ->
          {opts, llm_messages}
      end

    {:ok, pid} =
      Task.Supervisor.start_child(Liteskill.TaskSupervisor, fn ->
        StreamHandler.handle_stream(conversation.stream_id, llm_messages, opts)
      end)

    Process.monitor(pid)
    pid
  end

  defp maybe_unsubscribe(socket) do
    case socket.assigns[:conversation] do
      %{stream_id: stream_id} when not is_nil(stream_id) ->
        Phoenix.PubSub.unsubscribe(Liteskill.PubSub, "event_store:#{stream_id}")

      _ ->
        :ok
    end

    :ok
  end

  defp recover_stuck_stream(socket) do
    conversation = socket.assigns.conversation

    if conversation do
      user_id = socket.assigns.current_user.id

      Chat.recover_stream(conversation.id, user_id)
      Projector.sync()

      {:ok, messages} = Chat.list_messages(conversation.id, user_id)
      {:ok, fresh_conv} = Chat.get_conversation(conversation.id, user_id)

      assign(socket,
        streaming: false,
        stream_content: "",
        messages: messages,
        conversation: fresh_conv,
        pending_tool_calls: [],
        stream_task_pid: nil
      )
    else
      assign(socket, streaming: false, stream_content: "", stream_task_pid: nil)
    end
  end

  defp task_alive?(nil), do: false
  defp task_alive?(pid), do: Process.alive?(pid)
end
