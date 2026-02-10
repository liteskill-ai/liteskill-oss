defmodule LiteskillWeb.ChatLive do
  use LiteskillWeb, :live_view

  alias Liteskill.Chat
  alias Liteskill.Chat.ToolCall
  alias Liteskill.LLM.StreamHandler
  alias Liteskill.McpServers
  alias Liteskill.McpServers.Client, as: McpClient
  alias Liteskill.Repo
  alias LiteskillWeb.ChatComponents

  import Ecto.Query

  @impl true
  def mount(_params, _session, socket) do
    conversations = Chat.list_conversations(socket.assigns.current_user.id)

    {:ok,
     socket
     |> assign(
       conversations: conversations,
       conversation: nil,
       messages: [],
       form: to_form(%{"content" => ""}, as: :message),
       streaming: false,
       stream_content: "",
       mcp_servers: [],
       show_mcp_modal: false,
       mcp_form:
         to_form(
           %{
             "name" => "",
             "url" => "",
             "api_key" => "",
             "description" => "",
             "headers" => "",
             "global" => false
           },
           as: :mcp_server
         ),
       editing_mcp: nil,
       # Tool picker state
       available_tools: [],
       selected_server_ids: MapSet.new(),
       show_tool_picker: false,
       auto_confirm_tools: true,
       pending_tool_calls: [],
       tools_loading: false,
       stream_task_pid: nil,
       inspecting_server: nil,
       inspecting_tools: [],
       inspecting_tools_loading: false,
       sidebar_open: true,
       reports: [],
       report: nil,
       report_markdown: "",
       section_tree: [],
       report_comments: [],
       editing_section_id: nil,
       report_mode: :view
     ), layout: {LiteskillWeb.Layouts, :chat}}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> push_event("nav", %{})
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    # Unsubscribe from previous conversation if any
    maybe_unsubscribe(socket)

    socket
    |> assign(
      conversation: nil,
      messages: [],
      streaming: false,
      stream_content: "",
      pending_tool_calls: [],
      page_title: "Liteskill"
    )
  end

  defp apply_action(socket, :mcp_servers, _params) do
    maybe_unsubscribe(socket)
    user_id = socket.assigns.current_user.id
    servers = McpServers.list_servers(user_id)

    socket
    |> assign(
      conversation: nil,
      messages: [],
      streaming: false,
      stream_content: "",
      mcp_servers: servers,
      show_mcp_modal: false,
      editing_mcp: nil,
      pending_tool_calls: [],
      page_title: "MCP Servers"
    )
  end

  defp apply_action(socket, :reports, _params) do
    maybe_unsubscribe(socket)
    user_id = socket.assigns.current_user.id
    reports = Liteskill.Reports.list_reports(user_id)

    socket
    |> assign(
      conversation: nil,
      messages: [],
      streaming: false,
      stream_content: "",
      pending_tool_calls: [],
      reports: reports,
      page_title: "Reports"
    )
  end

  defp apply_action(socket, :report_show, %{"report_id" => report_id}) do
    maybe_unsubscribe(socket)
    user_id = socket.assigns.current_user.id

    case Liteskill.Reports.get_report(report_id, user_id) do
      {:ok, report} ->
        markdown = Liteskill.Reports.render_markdown(report, include_comments: false)
        section_tree = Liteskill.Reports.section_tree(report)

        report_comments =
          case Liteskill.Reports.get_report_comments(report_id, user_id) do
            {:ok, comments} -> comments
            _ -> []
          end

        socket
        |> assign(
          conversation: nil,
          messages: [],
          streaming: false,
          stream_content: "",
          pending_tool_calls: [],
          report: report,
          report_markdown: markdown,
          section_tree: section_tree,
          report_comments: report_comments,
          editing_section_id: nil,
          report_mode: :view,
          page_title: report.title
        )

      {:error, _} ->
        socket
        |> put_flash(:error, "Report not found")
        |> push_navigate(to: ~p"/reports")
    end
  end

  defp apply_action(socket, :show, %{"conversation_id" => conversation_id}) do
    user_id = socket.assigns.current_user.id

    # Unsubscribe from previous conversation
    maybe_unsubscribe(socket)

    case Chat.get_conversation(conversation_id, user_id) do
      {:ok, conversation} ->
        # Subscribe to PubSub for real-time updates
        topic = "event_store:#{conversation.stream_id}"
        Phoenix.PubSub.subscribe(Liteskill.PubSub, topic)

        streaming = conversation.status == "streaming"
        pending = if streaming, do: load_pending_tool_calls(conversation.messages), else: []

        socket
        |> assign(
          conversation: conversation,
          messages: conversation.messages,
          streaming: streaming,
          stream_content: "",
          pending_tool_calls: pending,
          page_title: conversation.title
        )

      {:error, _} ->
        socket
        |> put_flash(:error, "Conversation not found")
        |> push_navigate(to: ~p"/")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen relative">
      <%!-- Sidebar --%>
      <aside
        id="sidebar"
        phx-hook="SidebarNav"
        class={[
          "flex-shrink-0 bg-base-200 flex flex-col border-r border-base-300 transition-all duration-200 overflow-hidden",
          if(@sidebar_open,
            do: "w-64 max-sm:fixed max-sm:inset-0 max-sm:w-full max-sm:z-40",
            else: "w-0 border-r-0"
          )
        ]}
      >
        <div class="flex items-center justify-between p-3 border-b border-base-300 min-w-64">
          <img src={~p"/images/logo.svg"} class="size-7" />
          <div class="flex items-center gap-1">
            <Layouts.theme_toggle />
            <button phx-click="toggle_sidebar" class="btn btn-circle btn-ghost btn-sm">
              <.icon name="hero-arrow-left-end-on-rectangle-micro" class="size-5" />
            </button>
          </div>
        </div>

        <div class="p-3 min-w-64">
          <button
            phx-click="new_conversation"
            class="btn btn-neutral btn-sm w-full gap-2"
          >
            <.icon name="hero-plus-micro" class="size-4" /> New Chat
          </button>
        </div>

        <nav class="flex-1 overflow-y-auto px-2 space-y-1 pb-4 min-w-64">
          <ChatComponents.conversation_item
            :for={conv <- @conversations}
            conversation={conv}
            active={@conversation && @conversation.id == conv.id}
          />
          <p
            :if={@conversations == []}
            class="text-xs text-base-content/50 text-center py-4"
          >
            No conversations yet
          </p>
        </nav>

        <div class="p-2 border-t border-base-300 min-w-64">
          <.link
            navigate={~p"/mcp"}
            class={[
              "flex items-center gap-2 w-full px-3 py-2 rounded-lg text-sm transition-colors",
              if(@live_action == :mcp_servers,
                do: "bg-primary/10 text-primary font-medium",
                else: "hover:bg-base-200 text-base-content/70"
              )
            ]}
          >
            <.icon name="hero-server-stack-micro" class="size-4" /> MCP Servers
          </.link>
          <.link
            navigate={~p"/reports"}
            class={[
              "flex items-center gap-2 w-full px-3 py-2 rounded-lg text-sm transition-colors",
              if(@live_action in [:reports, :report_show],
                do: "bg-primary/10 text-primary font-medium",
                else: "hover:bg-base-200 text-base-content/70"
              )
            ]}
          >
            <.icon name="hero-document-text-micro" class="size-4" /> Reports
          </.link>
        </div>

        <div class="p-3 border-t border-base-300 min-w-64">
          <div class="flex items-center gap-2">
            <div class="flex-1 truncate text-sm text-base-content/70">
              {@current_user.email}
            </div>
            <.link href={~p"/auth/logout"} method="delete" class="btn btn-ghost btn-xs">
              <.icon name="hero-arrow-right-start-on-rectangle-micro" class="size-4" />
            </.link>
          </div>
        </div>
      </aside>

      <%!-- Main Area --%>
      <main class="flex-1 flex flex-col min-w-0">
        <%= if @live_action == :mcp_servers do %>
          <%!-- MCP Servers --%>
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
                <h1 class="text-lg font-semibold">MCP Servers</h1>
              </div>
              <button phx-click="show_add_mcp" class="btn btn-primary btn-sm gap-1">
                <.icon name="hero-plus-micro" class="size-4" /> Add Server
              </button>
            </div>
          </header>

          <div class="flex-1 overflow-y-auto p-4">
            <div
              :if={@mcp_servers != []}
              class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4"
            >
              <ChatComponents.mcp_server_card
                :for={server <- @mcp_servers}
                server={server}
                owned={server.user_id == @current_user.id}
              />
            </div>
            <p
              :if={@mcp_servers == []}
              class="text-base-content/50 text-center py-12"
            >
              No MCP servers configured yet. Click "Add Server" to get started.
            </p>
          </div>

          <ChatComponents.modal
            id="mcp-modal"
            title={if @editing_mcp, do: "Edit Server", else: "Add Server"}
            show={@show_mcp_modal}
            on_close="close_mcp_modal"
          >
            <.form for={@mcp_form} phx-submit="save_mcp" class="space-y-4">
              <input :if={@editing_mcp} type="hidden" name="mcp_server[id]" value={@editing_mcp.id} />
              <div class="form-control">
                <label class="label"><span class="label-text">Name *</span></label>
                <input
                  type="text"
                  name="mcp_server[name]"
                  value={Phoenix.HTML.Form.input_value(@mcp_form, :name)}
                  class="input input-bordered w-full"
                  required
                />
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">URL *</span></label>
                <input
                  type="url"
                  name="mcp_server[url]"
                  value={Phoenix.HTML.Form.input_value(@mcp_form, :url)}
                  class="input input-bordered w-full"
                  required
                />
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">API Key</span></label>
                <input
                  type="password"
                  name="mcp_server[api_key]"
                  value={Phoenix.HTML.Form.input_value(@mcp_form, :api_key)}
                  class="input input-bordered w-full"
                  autocomplete="off"
                />
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">Description</span></label>
                <textarea
                  name="mcp_server[description]"
                  class="textarea textarea-bordered w-full"
                  rows="2"
                >{Phoenix.HTML.Form.input_value(@mcp_form, :description)}</textarea>
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">Custom Headers (JSON)</span></label>
                <textarea
                  name="mcp_server[headers]"
                  class="textarea textarea-bordered w-full font-mono text-xs"
                  rows="3"
                  placeholder="{}"
                >{Phoenix.HTML.Form.input_value(@mcp_form, :headers)}</textarea>
              </div>
              <div class="form-control">
                <label class="label cursor-pointer justify-start gap-3">
                  <input
                    type="hidden"
                    name="mcp_server[global]"
                    value="false"
                  />
                  <input
                    type="checkbox"
                    name="mcp_server[global]"
                    value="true"
                    checked={
                      Phoenix.HTML.Form.input_value(@mcp_form, :global) == true ||
                        Phoenix.HTML.Form.input_value(@mcp_form, :global) == "true"
                    }
                    class="checkbox checkbox-sm"
                  />
                  <span class="label-text">Share globally with all users</span>
                </label>
              </div>
              <div class="flex justify-end gap-2 pt-2">
                <button type="button" phx-click="close_mcp_modal" class="btn btn-ghost btn-sm">
                  Cancel
                </button>
                <button type="submit" class="btn btn-primary btn-sm">
                  {if @editing_mcp, do: "Update", else: "Create"}
                </button>
              </div>
            </.form>
          </ChatComponents.modal>
        <% end %>
        <%= if @live_action == :reports do %>
          <%!-- Reports --%>
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
                <h1 class="text-lg font-semibold">Reports</h1>
              </div>
            </div>
          </header>

          <div class="flex-1 overflow-y-auto p-4">
            <div
              :if={@reports != []}
              class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4"
            >
              <ChatComponents.report_card
                :for={report <- @reports}
                report={report}
                owned={report.user_id == @current_user.id}
              />
            </div>
            <p
              :if={@reports == []}
              class="text-base-content/50 text-center py-12"
            >
              No reports yet. Use the Reports tools in a conversation to create one.
            </p>
          </div>
        <% end %>
        <%= if @live_action == :report_show do %>
          <%!-- Report Detail --%>
          <header
            id="report-detail"
            phx-hook="DownloadMarkdown"
            class="px-4 py-3 border-b border-base-300 flex-shrink-0"
          >
            <div class="flex flex-wrap items-center justify-between gap-2">
              <div class="flex items-center gap-2 min-w-0">
                <button
                  :if={!@sidebar_open}
                  phx-click="toggle_sidebar"
                  class="btn btn-circle btn-ghost btn-sm"
                >
                  <.icon name="hero-bars-3-micro" class="size-5" />
                </button>
                <.link navigate={~p"/reports"} class="btn btn-ghost btn-sm btn-circle">
                  <.icon name="hero-arrow-left-micro" class="size-5" />
                </.link>
                <h1 class="text-lg font-semibold truncate">{@report && @report.title}</h1>
              </div>
              <div class="flex flex-wrap gap-1">
                <%= if @report_mode == :view do %>
                  <button phx-click="report_edit_mode" class="btn btn-ghost btn-sm gap-1">
                    <.icon name="hero-pencil-square-micro" class="size-4" /> Edit
                  </button>
                <% else %>
                  <button phx-click="address_comments" class="btn btn-primary btn-sm gap-1">
                    <.icon name="hero-chat-bubble-left-right-micro" class="size-4" /> Address Comments
                  </button>
                  <button phx-click="report_view_mode" class="btn btn-ghost btn-sm gap-1">
                    <.icon name="hero-eye-micro" class="size-4" /> View
                  </button>
                <% end %>
                <button phx-click="export_report" class="btn btn-ghost btn-sm gap-1">
                  <.icon name="hero-arrow-down-tray-micro" class="size-4" /> Export
                </button>
              </div>
            </div>
          </header>

          <div class="flex-1 overflow-y-auto px-6 py-6 space-y-6">
            <%= if @report_mode == :view do %>
              <%!-- View mode: clean markdown rendering --%>
              <div
                :if={@report_markdown != ""}
                id="report-markdown"
                phx-hook="CopyCode"
                class="prose prose-sm max-w-none"
              >
                {LiteskillWeb.Markdown.render(@report_markdown)}
              </div>
              <p
                :if={@report_markdown == ""}
                class="text-base-content/50 text-center py-12"
              >
                This report has no content yet. Use the Reports tools in a conversation to add content.
              </p>
            <% else %>
              <%!-- Edit mode: section tree with comments and inline editing --%>
              <div :if={@report_comments != []} class="space-y-2">
                <h3 class="text-sm font-semibold text-base-content/70">Report Comments</h3>
                <ChatComponents.section_comment :for={c <- @report_comments} comment={c} />
              </div>

              <form phx-submit="add_report_comment" class="flex gap-2">
                <input
                  type="text"
                  name="body"
                  placeholder="Add a report comment..."
                  class="input input-bordered input-sm flex-1"
                />
                <button type="submit" class="btn btn-sm btn-ghost">Comment</button>
              </form>

              <div :if={@section_tree != []} class="space-y-4">
                <ChatComponents.section_node
                  :for={node <- @section_tree}
                  node={node}
                  depth={1}
                  editing_section_id={@editing_section_id}
                />
              </div>

              <p
                :if={@section_tree == [] && @report_comments == []}
                class="text-base-content/50 text-center py-12"
              >
                This report has no sections yet. Use the Reports tools in a conversation to add content.
              </p>
            <% end %>
          </div>
        <% end %>
        <%= if @live_action not in [:mcp_servers, :reports, :report_show] do %>
          <%= if @conversation do %>
            <%!-- Active conversation --%>
            <header class="px-4 py-3 border-b border-base-300 flex-shrink-0">
              <div class="flex items-center gap-2">
                <button
                  :if={!@sidebar_open}
                  phx-click="toggle_sidebar"
                  class="btn btn-circle btn-ghost btn-sm"
                >
                  <.icon name="hero-bars-3-micro" class="size-5" />
                </button>
                <h1 class="text-lg font-semibold truncate">{@conversation.title}</h1>
              </div>
            </header>

            <div id="messages" phx-hook="ScrollBottom" class="flex-1 overflow-y-auto px-4 py-4">
              <%= for msg <- @messages do %>
                <ChatComponents.message_bubble
                  :if={msg.content && msg.content != ""}
                  message={msg}
                />
                <%!-- Tool calls for completed messages (inline) --%>
                <%= if msg.role == "assistant" && msg.stop_reason == "tool_use" do %>
                  <%= for tc <- tool_calls_for_message(msg) do %>
                    <ChatComponents.tool_call_display
                      tool_call={tc}
                      show_actions={!@auto_confirm_tools && tc.status == "started"}
                    />
                  <% end %>
                <% end %>
              <% end %>
              <div :if={@streaming && @stream_content != ""} class="mb-4 text-base-content">
                <div id="streaming-prose" phx-hook="CopyCode" class="prose prose-sm max-w-none">
                  {LiteskillWeb.Markdown.render_streaming(@stream_content)}
                </div>
              </div>
              <ChatComponents.streaming_indicator :if={@streaming && @stream_content == ""} />
              <%!-- Pending tool calls from streaming message (rendered from socket state, not DB) --%>
              <%= for tc <- @pending_tool_calls do %>
                <ChatComponents.tool_call_display
                  tool_call={tc}
                  show_actions={!@auto_confirm_tools && tc.status == "started"}
                />
              <% end %>
            </div>

            <div class="flex-shrink-0 border-t border-base-300 px-4 py-3">
              <ChatComponents.selected_server_badges
                available_tools={@available_tools}
                selected_server_ids={@selected_server_ids}
              />
              <.form for={@form} phx-submit="send_message" class="flex gap-2 items-center">
                <ChatComponents.server_picker
                  available_tools={@available_tools}
                  selected_server_ids={@selected_server_ids}
                  show={@show_tool_picker}
                  auto_confirm={@auto_confirm_tools}
                  tools_loading={@tools_loading}
                />
                <div class="flex-1">
                  <textarea
                    id="message-input"
                    name="message[content]"
                    phx-hook="TextareaAutoResize"
                    placeholder="Type a message..."
                    rows="1"
                    class="textarea textarea-bordered w-full resize-none min-h-[2.5rem] max-h-40"
                    disabled={@streaming}
                  >{Phoenix.HTML.Form.input_value(@form, :content)}</textarea>
                </div>
                <button
                  :if={!@streaming}
                  type="submit"
                  class="btn btn-primary btn-sm"
                >
                  <.icon name="hero-paper-airplane-micro" class="size-4" />
                </button>
                <button
                  :if={@streaming}
                  type="button"
                  phx-click="cancel_stream"
                  class="btn btn-error btn-sm"
                >
                  <.icon name="hero-stop-micro" class="size-4" />
                </button>
              </.form>
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
                <ChatComponents.selected_server_badges
                  available_tools={@available_tools}
                  selected_server_ids={@selected_server_ids}
                />
                <.form for={@form} phx-submit="send_message" class="flex gap-2 items-center">
                  <ChatComponents.server_picker
                    available_tools={@available_tools}
                    selected_server_ids={@selected_server_ids}
                    show={@show_tool_picker}
                    auto_confirm={@auto_confirm_tools}
                    tools_loading={@tools_loading}
                  />
                  <div class="flex-1">
                    <textarea
                      id="message-input"
                      name="message[content]"
                      phx-hook="TextareaAutoResize"
                      placeholder="Type a message..."
                      rows="1"
                      class="textarea textarea-bordered w-full resize-none min-h-[2.5rem] max-h-40"
                    />
                  </div>
                  <button type="submit" class="btn btn-primary btn-sm">
                    <.icon name="hero-paper-airplane-micro" class="size-4" />
                  </button>
                </.form>
              </div>
            </div>
          <% end %>
        <% end %>
      </main>

      <ChatComponents.modal
        id="tools-modal"
        title={if @inspecting_server, do: "#{@inspecting_server.name} — Tools", else: "Tools"}
        show={@inspecting_server != nil}
        on_close="close_tools_modal"
      >
        <div :if={@inspecting_tools_loading} class="text-center py-8 text-base-content/50">
          Loading tools...
        </div>
        <div
          :if={!@inspecting_tools_loading && @inspecting_tools == []}
          class="text-center py-8 text-base-content/50"
        >
          No tools found on this server.
        </div>
        <div :if={!@inspecting_tools_loading && @inspecting_tools != []} class="space-y-3">
          <ChatComponents.tool_detail :for={tool <- @inspecting_tools} tool={tool} />
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

  @impl true
  def handle_event("new_conversation", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  @impl true
  def handle_event("select_conversation", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/c/#{id}")}
  end

  @impl true
  def handle_event("send_message", %{"message" => %{"content" => content}}, socket) do
    content = String.trim(content)

    if content == "" do
      {:noreply, socket}
    else
      user_id = socket.assigns.current_user.id

      case socket.assigns.conversation do
        nil ->
          # Create new conversation, send message, navigate to it
          case Chat.create_conversation(%{user_id: user_id, title: truncate_title(content)}) do
            {:ok, conversation} ->
              case Chat.send_message(conversation.id, user_id, content) do
                {:ok, _message} ->
                  pid = trigger_llm_stream(conversation, user_id, socket)

                  {:noreply,
                   socket
                   |> assign(stream_task_pid: pid)
                   |> push_navigate(to: ~p"/c/#{conversation.id}")}

                {:error, _reason} ->
                  {:noreply, put_flash(socket, :error, "Failed to send message")}
              end

            {:error, _reason} ->
              {:noreply, put_flash(socket, :error, "Failed to create conversation")}
          end

        conversation ->
          # Send message to existing conversation
          case Chat.send_message(conversation.id, user_id, content) do
            {:ok, _message} ->
              # Reload messages and trigger LLM
              {:ok, messages} = Chat.list_messages(conversation.id, user_id)
              pid = trigger_llm_stream(conversation, user_id, socket)

              {:noreply,
               socket
               |> assign(
                 messages: messages,
                 form: to_form(%{"content" => ""}, as: :message),
                 streaming: true,
                 stream_content: "",
                 pending_tool_calls: [],
                 stream_task_pid: pid
               )}

            {:error, _reason} ->
              {:noreply, put_flash(socket, :error, "Failed to send message")}
          end
      end
    end
  end

  @impl true
  def handle_event("delete_conversation", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Chat.archive_conversation(id, user_id) do
      {:ok, _} ->
        conversations = Chat.list_conversations(user_id)

        {:noreply,
         socket
         |> assign(conversations: conversations)
         |> push_navigate(to: ~p"/")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete conversation")}
    end
  end

  @impl true
  def handle_event("cancel_stream", _params, socket) do
    {:noreply, recover_stuck_stream(socket)}
  end

  # --- Tool Picker Events ---

  @impl true
  def handle_event("toggle_tool_picker", _params, socket) do
    show = !socket.assigns.show_tool_picker

    if show && socket.assigns.available_tools == [] do
      # Fetch tools when opening picker for the first time
      send(self(), :fetch_tools)
      {:noreply, assign(socket, show_tool_picker: true, tools_loading: true)}
    else
      {:noreply, assign(socket, show_tool_picker: show)}
    end
  end

  @impl true
  def handle_event("toggle_server", %{"server-id" => server_id}, socket) do
    selected = socket.assigns.selected_server_ids

    selected =
      if MapSet.member?(selected, server_id) do
        MapSet.delete(selected, server_id)
      else
        MapSet.put(selected, server_id)
      end

    {:noreply, assign(socket, selected_server_ids: selected)}
  end

  @impl true
  def handle_event("toggle_auto_confirm", _params, socket) do
    {:noreply, assign(socket, auto_confirm_tools: !socket.assigns.auto_confirm_tools)}
  end

  @impl true
  def handle_event("clear_tools", _params, socket) do
    {:noreply, assign(socket, selected_server_ids: MapSet.new())}
  end

  @impl true
  def handle_event("refresh_tools", _params, socket) do
    send(self(), :fetch_tools)
    {:noreply, assign(socket, tools_loading: true, available_tools: [])}
  end

  @impl true
  def handle_event("approve_tool_call", %{"tool-use-id" => tool_use_id}, socket) do
    stream_id = socket.assigns.conversation.stream_id

    Phoenix.PubSub.broadcast(
      Liteskill.PubSub,
      "tool_approval:#{stream_id}",
      {:tool_decision, tool_use_id, :approved}
    )

    {:noreply, socket}
  end

  @impl true
  def handle_event("reject_tool_call", %{"tool-use-id" => tool_use_id}, socket) do
    stream_id = socket.assigns.conversation.stream_id

    Phoenix.PubSub.broadcast(
      Liteskill.PubSub,
      "tool_approval:#{stream_id}",
      {:tool_decision, tool_use_id, :rejected}
    )

    {:noreply, socket}
  end

  # --- MCP Server Events ---

  @impl true
  def handle_event("show_add_mcp", _params, socket) do
    {:noreply,
     assign(socket,
       show_mcp_modal: true,
       editing_mcp: nil,
       mcp_form:
         to_form(
           %{
             "name" => "",
             "url" => "",
             "api_key" => "",
             "description" => "",
             "headers" => "",
             "global" => false
           },
           as: :mcp_server
         )
     )}
  end

  @impl true
  def handle_event("edit_mcp", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case McpServers.get_server(id, user_id) do
      {:ok, server} ->
        headers_json =
          case server.headers do
            nil -> ""
            h when h == %{} -> ""
            h -> Jason.encode!(h, pretty: true)
          end

        {:noreply,
         assign(socket,
           show_mcp_modal: true,
           editing_mcp: server,
           mcp_form:
             to_form(
               %{
                 "name" => server.name,
                 "url" => server.url,
                 "api_key" => server.api_key || "",
                 "description" => server.description || "",
                 "headers" => headers_json,
                 "global" => server.global
               },
               as: :mcp_server
             )
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Server not found")}
    end
  end

  @impl true
  def handle_event("close_mcp_modal", _params, socket) do
    {:noreply, assign(socket, show_mcp_modal: false, editing_mcp: nil)}
  end

  @impl true
  def handle_event("save_mcp", %{"mcp_server" => params}, socket) do
    user_id = socket.assigns.current_user.id

    headers = parse_headers(params["headers"])
    attrs = Map.merge(params, %{"headers" => headers, "user_id" => user_id})

    result =
      case socket.assigns.editing_mcp do
        nil ->
          McpServers.create_server(attrs)

        server ->
          McpServers.update_server(server, user_id, attrs)
      end

    case result do
      {:ok, _server} ->
        servers = McpServers.list_servers(user_id)

        {:noreply,
         socket
         |> assign(mcp_servers: servers, show_mcp_modal: false, editing_mcp: nil)
         |> put_flash(:info, "Server saved")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(mcp_form: to_form(changeset, as: :mcp_server))
         |> put_flash(:error, "Please fix the errors")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Error: #{reason}")}
    end
  end

  @impl true
  def handle_event("delete_mcp", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case McpServers.delete_server(id, user_id) do
      {:ok, _} ->
        servers = McpServers.list_servers(user_id)
        {:noreply, assign(socket, mcp_servers: servers)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete server")}
    end
  end

  @impl true
  def handle_event("delete_report", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Liteskill.Reports.delete_report(id, user_id) do
      {:ok, _} ->
        reports = Liteskill.Reports.list_reports(user_id)
        {:noreply, assign(socket, reports: reports)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete report")}
    end
  end

  @impl true
  def handle_event("leave_report", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Liteskill.Reports.leave_report(id, user_id) do
      {:ok, _} ->
        reports = Liteskill.Reports.list_reports(user_id)
        {:noreply, assign(socket, reports: reports)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to leave report")}
    end
  end

  @impl true
  def handle_event("export_report", _params, socket) do
    report = socket.assigns.report
    markdown = socket.assigns.report_markdown

    filename =
      report.title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> Kernel.<>(".md")

    {:noreply, push_event(socket, "download_markdown", %{filename: filename, content: markdown})}
  end

  @impl true
  def handle_event("add_section_comment", %{"section_id" => section_id, "body" => body}, socket) do
    body = String.trim(body)

    if body == "" do
      {:noreply, socket}
    else
      user_id = socket.assigns.current_user.id
      Liteskill.Reports.add_comment(section_id, user_id, body, "user")
      {:noreply, reload_report(socket)}
    end
  end

  @impl true
  def handle_event("add_report_comment", %{"body" => body}, socket) do
    body = String.trim(body)

    if body == "" do
      {:noreply, socket}
    else
      user_id = socket.assigns.current_user.id
      report_id = socket.assigns.report.id
      Liteskill.Reports.add_report_comment(report_id, user_id, body, "user")
      {:noreply, reload_report(socket)}
    end
  end

  @impl true
  def handle_event("reply_to_comment", %{"comment_id" => comment_id, "body" => body}, socket) do
    body = String.trim(body)

    if body == "" do
      {:noreply, socket}
    else
      user_id = socket.assigns.current_user.id
      Liteskill.Reports.reply_to_comment(comment_id, user_id, body, "user")
      {:noreply, reload_report(socket)}
    end
  end

  @impl true
  def handle_event("report_edit_mode", _params, socket) do
    {:noreply, socket |> assign(report_mode: :edit, editing_section_id: nil) |> reload_report()}
  end

  @impl true
  def handle_event("report_view_mode", _params, socket) do
    {:noreply, socket |> assign(report_mode: :view, editing_section_id: nil) |> reload_report()}
  end

  @impl true
  def handle_event("edit_section", %{"section-id" => section_id}, socket) do
    {:noreply, assign(socket, editing_section_id: section_id)}
  end

  @impl true
  def handle_event("cancel_edit_section", _params, socket) do
    {:noreply, assign(socket, editing_section_id: nil)}
  end

  @impl true
  def handle_event("save_section", params, socket) do
    section_id = params["section-id"]
    user_id = socket.assigns.current_user.id

    attrs =
      %{}
      |> then(fn a ->
        if params["content"], do: Map.put(a, :content, params["content"]), else: a
      end)
      |> then(fn a ->
        title = params["title"]

        if is_binary(title) && String.trim(title) != "",
          do: Map.put(a, :title, String.trim(title)),
          else: a
      end)

    case Liteskill.Reports.update_section_content(section_id, user_id, attrs) do
      {:ok, _section} ->
        {:noreply, socket |> assign(editing_section_id: nil) |> reload_report()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update section")}
    end
  end

  @impl true
  def handle_event("address_comments", _params, socket) do
    user_id = socket.assigns.current_user.id
    report = socket.assigns.report

    system_prompt =
      "You are a report editing assistant. You have access to the Reports tools. " <>
        "When asked to address comments, use reports__get to read the report and see all comments. " <>
        "For each [OPEN] comment, make meaningful section updates using reports__modify_sections, " <>
        "then mark the comment as addressed using reports__comment with the \"resolve\" action. " <>
        "If you are unsure how to address a comment, add an agent comment with your question " <>
        "rather than making incorrect changes."

    case Chat.create_conversation(%{
           user_id: user_id,
           title: "Address comments: #{report.title}",
           system_prompt: system_prompt
         }) do
      {:ok, conversation} ->
        content =
          "Please address all unaddressed comments on report #{report.id}. " <>
            "Read the report first, then update sections to address each open comment."

        case Chat.send_message(conversation.id, user_id, content) do
          {:ok, _message} ->
            # Pre-select Reports builtin tools, then trigger the LLM stream
            socket = ensure_tools_loaded(socket)
            socket = select_reports_server(socket)
            pid = trigger_llm_stream(conversation, user_id, socket)

            {:noreply,
             socket
             |> assign(stream_task_pid: pid)
             |> push_navigate(to: ~p"/c/#{conversation.id}")}

          # coveralls-ignore-start
          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Failed to send message")}
            # coveralls-ignore-stop
        end

      # coveralls-ignore-start
      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create conversation")}
        # coveralls-ignore-stop
    end
  end

  @impl true
  def handle_event("toggle_mcp_status", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case McpServers.get_server(id, user_id) do
      {:ok, server} ->
        new_status = if server.status == "active", do: "inactive", else: "active"

        case McpServers.update_server(server, user_id, %{"status" => new_status}) do
          {:ok, _} ->
            servers = McpServers.list_servers(user_id)
            {:noreply, assign(socket, mcp_servers: servers)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to update status")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Server not found")}
    end
  end

  @impl true
  def handle_event("inspect_tools", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case McpServers.get_server(id, user_id) do
      {:ok, server} ->
        send(self(), {:fetch_server_tools, server})

        {:noreply,
         assign(socket,
           inspecting_server: server,
           inspecting_tools: [],
           inspecting_tools_loading: true
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Server not found")}
    end
  end

  @impl true
  def handle_event("close_tools_modal", _params, socket) do
    {:noreply,
     assign(socket, inspecting_server: nil, inspecting_tools: [], inspecting_tools_loading: false)}
  end

  # --- PubSub Handlers ---

  @impl true
  def handle_info({:events, _stream_id, events}, socket) do
    socket = Enum.reduce(events, socket, &handle_event_store_event/2)
    {:noreply, socket}
  end

  def handle_info(:reload_after_complete, socket) do
    user_id = socket.assigns.current_user.id
    conversation = socket.assigns.conversation

    {:ok, messages} = Chat.list_messages(conversation.id, user_id)
    conversations = Chat.list_conversations(user_id)

    # Reload conversation to check actual status — avoids race when
    # StreamHandler immediately starts a new round after completing
    {:ok, fresh_conv} = Chat.get_conversation(conversation.id, user_id)
    still_streaming = fresh_conv.status == "streaming"

    {:noreply,
     assign(socket,
       streaming: still_streaming,
       stream_content: if(still_streaming, do: socket.assigns.stream_content, else: ""),
       messages: messages,
       conversations: conversations,
       conversation: fresh_conv,
       pending_tool_calls: [],
       stream_task_pid: if(still_streaming, do: socket.assigns.stream_task_pid, else: nil)
     )}
  end

  def handle_info(:fetch_tools, socket) do
    user_id = socket.assigns.current_user.id
    servers = McpServers.list_servers(user_id)
    active_servers = Enum.filter(servers, &(&1.status == "active"))

    {builtin_servers, mcp_servers} =
      Enum.split_with(active_servers, &Map.has_key?(&1, :builtin))

    builtin_tools =
      Enum.flat_map(builtin_servers, fn server ->
        Enum.map(server.builtin.list_tools(), fn tool ->
          %{
            id: "#{server.id}:#{tool["name"]}",
            server_id: server.id,
            server_name: server.name,
            name: tool["name"],
            description: tool["description"],
            input_schema: tool["inputSchema"]
          }
        end)
      end)

    {mcp_tools, errors} =
      Enum.reduce(mcp_servers, {[], []}, fn server, {tools_acc, errors_acc} ->
        case McpClient.list_tools(server) do
          {:ok, tool_list} ->
            mapped =
              Enum.map(tool_list, fn tool ->
                %{
                  id: "#{server.id}:#{tool["name"]}",
                  server_id: server.id,
                  server_name: server.name,
                  name: tool["name"],
                  description: tool["description"],
                  input_schema: tool["inputSchema"]
                }
              end)

            {tools_acc ++ mapped, errors_acc}

          {:error, reason} ->
            require Logger
            Logger.warning("Failed to fetch tools from #{server.name}: #{inspect(reason)}")
            {tools_acc, errors_acc ++ ["#{server.name}: #{format_tool_error(reason)}"]}
        end
      end)

    socket = assign(socket, available_tools: builtin_tools ++ mcp_tools, tools_loading: false)

    socket =
      if errors != [] do
        put_flash(socket, :error, "Tool fetch failed: " <> Enum.join(errors, "; "))
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:fetch_server_tools, %{builtin: module}}, socket) do
    tools = module.list_tools()
    {:noreply, assign(socket, inspecting_tools: tools, inspecting_tools_loading: false)}
  end

  def handle_info({:fetch_server_tools, server}, socket) do
    case McpClient.list_tools(server) do
      {:ok, tools} ->
        {:noreply, assign(socket, inspecting_tools: tools, inspecting_tools_loading: false)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(inspecting_tools_loading: false)
         |> put_flash(:error, "Failed to fetch tools: #{format_tool_error(reason)}")}
    end
  end

  def handle_info(:reload_tool_calls, socket) do
    user_id = socket.assigns.current_user.id
    conversation = socket.assigns.conversation

    {:ok, messages} = Chat.list_messages(conversation.id, user_id)
    db_pending = load_pending_tool_calls(messages)

    # During streaming, load_pending_tool_calls returns [] because the message
    # hasn't completed with stop_reason: "tool_use" yet. Keep the in-memory
    # pending_tool_calls built from PubSub events in that case.
    pending =
      if db_pending != [] do
        db_pending
      else
        if socket.assigns.streaming && socket.assigns.pending_tool_calls != [] do
          socket.assigns.pending_tool_calls
        else
          []
        end
      end

    {:noreply, assign(socket, messages: messages, pending_tool_calls: pending)}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, socket)
      when reason != :normal do
    if socket.assigns.streaming && pid == socket.assigns.stream_task_pid do
      {:noreply, recover_stuck_stream(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp handle_event_store_event(
         %{event_type: "AssistantStreamStarted"},
         socket
       ) do
    assign(socket, streaming: true, stream_content: "")
  end

  defp handle_event_store_event(
         %{event_type: "AssistantChunkReceived", data: data},
         socket
       ) do
    delta = data["delta_text"] || ""
    assign(socket, stream_content: socket.assigns.stream_content <> delta)
  end

  defp handle_event_store_event(
         %{event_type: "AssistantStreamCompleted"},
         socket
       ) do
    # Delay reload to let the Projector finish updating the DB.
    # Keep streaming content visible until then.
    Process.send_after(self(), :reload_after_complete, 100)
    socket
  end

  defp handle_event_store_event(
         %{event_type: "AssistantStreamFailed"},
         socket
       ) do
    socket
    |> assign(streaming: false, stream_content: "")
    |> put_flash(:error, "Assistant response failed")
  end

  defp handle_event_store_event(
         %{event_type: "UserMessageAdded"},
         socket
       ) do
    # Reload messages (handles shared conversations)
    user_id = socket.assigns.current_user.id
    conversation = socket.assigns.conversation
    {:ok, messages} = Chat.list_messages(conversation.id, user_id)
    assign(socket, messages: messages)
  end

  defp handle_event_store_event(
         %{event_type: "ToolCallStarted", data: data},
         socket
       ) do
    # Build tool call immediately from event data to avoid race with projector
    tc = %ToolCall{
      tool_use_id: data["tool_use_id"],
      tool_name: data["tool_name"],
      input: data["input"],
      status: "started",
      message_id: data["message_id"]
    }

    pending = socket.assigns.pending_tool_calls ++ [tc]

    # Also schedule a DB reload to sync fully
    Process.send_after(self(), :reload_tool_calls, 500)
    assign(socket, pending_tool_calls: pending)
  end

  defp handle_event_store_event(
         %{event_type: "ToolCallCompleted", data: data},
         socket
       ) do
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

  defp trigger_llm_stream(conversation, user_id, socket) do
    {:ok, messages} = Chat.list_messages(conversation.id, user_id)

    llm_messages = build_llm_messages(messages)

    opts =
      if conversation.system_prompt do
        [system: conversation.system_prompt]
      else
        []
      end

    # Add tool options if tools are selected
    opts = opts ++ build_tool_opts(socket)

    {:ok, pid} =
      Task.start(fn ->
        StreamHandler.handle_stream(conversation.stream_id, llm_messages, opts)
      end)

    Process.monitor(pid)
    pid
  end

  defp build_tool_opts(socket) do
    selected = socket.assigns.selected_server_ids
    available = socket.assigns.available_tools

    # Select all tools from selected servers
    selected_tools = Enum.filter(available, &MapSet.member?(selected, &1.server_id))

    if selected_tools == [] do
      []
    else
      bedrock_tools =
        Enum.map(selected_tools, fn tool ->
          %{
            "toolSpec" => %{
              "name" => tool.name,
              "description" => tool.description || "",
              "inputSchema" => %{"json" => tool.input_schema || %{}}
            }
          }
        end)

      user_id = socket.assigns.current_user.id

      tool_servers =
        Map.new(selected_tools, fn tool ->
          server =
            case McpServers.get_server(tool.server_id, user_id) do
              {:ok, s} -> s
              _ -> nil
            end

          {tool.name, server}
        end)

      [
        tools: bedrock_tools,
        tool_servers: tool_servers,
        auto_confirm: socket.assigns.auto_confirm_tools,
        user_id: user_id
      ]
    end
  end

  defp reload_report(socket) do
    report = socket.assigns.report
    user_id = socket.assigns.current_user.id

    case Liteskill.Reports.get_report(report.id, user_id) do
      {:ok, report} ->
        section_tree = Liteskill.Reports.section_tree(report)

        report_comments =
          case Liteskill.Reports.get_report_comments(report.id, user_id) do
            {:ok, comments} -> comments
            _ -> []
          end

        include_comments = socket.assigns[:report_mode] != :view
        markdown = Liteskill.Reports.render_markdown(report, include_comments: include_comments)

        assign(socket,
          report: report,
          section_tree: section_tree,
          report_comments: report_comments,
          report_markdown: markdown
        )

      # coveralls-ignore-start
      {:error, _} ->
        socket
        # coveralls-ignore-stop
    end
  end

  defp ensure_tools_loaded(socket) do
    if socket.assigns.available_tools == [] do
      user_id = socket.assigns.current_user.id
      servers = Liteskill.McpServers.list_servers(user_id)
      active_servers = Enum.filter(servers, &(&1.status == "active"))

      builtin_tools =
        active_servers
        |> Enum.filter(&Map.has_key?(&1, :builtin))
        |> Enum.flat_map(fn server ->
          Enum.map(server.builtin.list_tools(), fn tool ->
            %{
              id: "#{server.id}:#{tool["name"]}",
              server_id: server.id,
              server_name: server.name,
              name: tool["name"],
              description: tool["description"],
              input_schema: tool["inputSchema"]
            }
          end)
        end)

      assign(socket, available_tools: builtin_tools)
    else
      socket
    end
  end

  defp select_reports_server(socket) do
    reports_server =
      Enum.find(socket.assigns.available_tools, fn tool ->
        String.starts_with?(tool.name, "reports__")
      end)

    case reports_server do
      nil ->
        socket

      tool ->
        assign(socket, selected_server_ids: MapSet.new([tool.server_id]))
    end
  end

  defp build_llm_messages(messages) do
    messages
    |> Repo.preload(:tool_calls)
    |> Enum.filter(&(&1.status == "complete"))
    |> Enum.reduce([], fn msg, acc ->
      case msg.role do
        "user" ->
          if msg.content && msg.content != "" do
            acc ++ [%{"role" => "user", "content" => [%{"text" => msg.content}]}]
          else
            acc
          end

        "assistant" ->
          if msg.stop_reason == "tool_use" do
            # Build assistant message with text + toolUse blocks
            text_blocks =
              if msg.content && msg.content != "" do
                [%{"text" => msg.content}]
              else
                []
              end

            completed_tcs = Enum.filter(msg.tool_calls, &(&1.status == "completed"))

            tool_use_blocks =
              Enum.map(msg.tool_calls, fn tc ->
                %{
                  "toolUse" => %{
                    "toolUseId" => tc.tool_use_id,
                    "name" => tc.tool_name,
                    "input" => tc.input || %{}
                  }
                }
              end)

            content = text_blocks ++ tool_use_blocks
            assistant_msg = %{"role" => "assistant", "content" => content}

            # Build tool result user message from completed tool calls
            if completed_tcs != [] do
              tool_results =
                Enum.map(completed_tcs, fn tc ->
                  %{
                    "toolResult" => %{
                      "toolUseId" => tc.tool_use_id,
                      "content" => [%{"text" => format_tool_output_for_msg(tc.output)}],
                      "status" => "success"
                    }
                  }
                end)

              acc ++ [assistant_msg, %{"role" => "user", "content" => tool_results}]
            else
              acc ++ [assistant_msg]
            end
          else
            if msg.content && msg.content != "" do
              acc ++ [%{"role" => "assistant", "content" => [%{"text" => msg.content}]}]
            else
              acc
            end
          end
      end
    end)
    |> merge_consecutive_roles()
  end

  # Merge consecutive same-role messages (can happen when failed assistant
  # messages are filtered out, leaving adjacent user messages).
  defp merge_consecutive_roles(messages) do
    messages
    |> Enum.chunk_while(
      nil,
      fn msg, acc ->
        case acc do
          nil ->
            {:cont, msg}

          %{"role" => role} ->
            if role == msg["role"] do
              merged = %{acc | "content" => acc["content"] ++ msg["content"]}
              {:cont, merged}
            else
              {:cont, acc, msg}
            end
        end
      end,
      fn
        nil -> {:cont, []}
        acc -> {:cont, acc, nil}
      end
    )
  end

  defp format_tool_output_for_msg(nil), do: ""

  defp format_tool_output_for_msg(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => text} -> text
      other -> Jason.encode!(other)
    end)
    |> Enum.join("\n")
  end

  defp format_tool_output_for_msg(output) when is_map(output), do: Jason.encode!(output)
  defp format_tool_output_for_msg(output), do: inspect(output)

  defp tool_calls_for_message(msg) do
    case msg.tool_calls do
      %Ecto.Association.NotLoaded{} ->
        Repo.all(
          from tc in ToolCall, where: tc.message_id == ^msg.id, order_by: [asc: tc.inserted_at]
        )

      tool_calls ->
        tool_calls
    end
  end

  defp load_pending_tool_calls(messages) do
    case List.last(messages) do
      %{role: "assistant", stop_reason: "tool_use"} = msg ->
        tool_calls_for_message(msg)
        |> Enum.filter(&(&1.status == "started"))

      _ ->
        []
    end
  end

  defp maybe_unsubscribe(socket) do
    case socket.assigns[:conversation] do
      %{stream_id: stream_id} when not is_nil(stream_id) ->
        Phoenix.PubSub.unsubscribe(Liteskill.PubSub, "event_store:#{stream_id}")

      _ ->
        :ok
    end
  end

  defp truncate_title(content) do
    case String.split(content, "\n", parts: 2) do
      [first | _] ->
        if String.length(first) > 50 do
          String.slice(first, 0, 47) <> "..."
        else
          first
        end
    end
  end

  defp parse_headers(str) when is_binary(str) do
    str = String.trim(str)

    if str == "" do
      %{}
    else
      case Jason.decode(str) do
        {:ok, map} when is_map(map) -> map
        _ -> %{}
      end
    end
  end

  defp parse_headers(_), do: %{}

  defp recover_stuck_stream(socket) do
    conversation = socket.assigns.conversation

    if conversation do
      user_id = socket.assigns.current_user.id

      # Find the streaming message to get its ID for fail_stream
      streaming_msg =
        Repo.one(
          from m in Liteskill.Chat.Message,
            where: m.conversation_id == ^conversation.id and m.status == "streaming",
            order_by: [desc: m.inserted_at],
            limit: 1
        )

      if streaming_msg do
        alias Liteskill.Aggregate.Loader
        alias Liteskill.Chat.{ConversationAggregate, Projector}

        command =
          {:fail_stream,
           %{
             message_id: streaming_msg.id,
             error_type: "task_crashed",
             error_message: "Stream handler process terminated unexpectedly"
           }}

        case Loader.execute(ConversationAggregate, conversation.stream_id, command) do
          {:ok, _state, events} ->
            Projector.project_events(conversation.stream_id, events)
            Process.sleep(100)

          {:error, _reason} ->
            :ok
        end
      end

      {:ok, messages} = Chat.list_messages(conversation.id, user_id)
      {:ok, fresh_conv} = Chat.get_conversation(conversation.id, user_id)

      socket
      |> assign(
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

  defp format_tool_error(%{status: status, body: body}) when is_binary(body),
    do: "HTTP #{status}: #{String.slice(body, 0..100)}"

  defp format_tool_error(%{status: status}), do: "HTTP #{status}"
  defp format_tool_error(%Req.TransportError{reason: reason}), do: "Connection error: #{reason}"
  defp format_tool_error(reason) when is_binary(reason), do: reason
  defp format_tool_error(reason), do: inspect(reason)
end
