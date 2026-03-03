defmodule LiteskillWeb.McpLive do
  @moduledoc """
  Standalone LiveView for MCP server management: listing, creating, editing,
  deleting tool servers and inspecting their available tools.
  """

  use LiteskillWeb, :live_view

  alias Liteskill.Chat
  alias Liteskill.McpServers
  alias Liteskill.McpServers.Client, as: McpClient
  alias LiteskillWeb.ChatComponents
  alias LiteskillWeb.Layouts
  alias LiteskillWeb.McpComponents

  # --- LiveView callbacks ---

  @impl true
  def mount(_params, _session, socket) do
    conversations = Chat.list_conversations(socket.assigns.current_user.id)

    {:ok,
     assign(socket,
       conversations: conversations,
       conversation: nil,
       sidebar_open: true,
       has_admin_access: Liteskill.Rbac.has_any_admin_permission?(socket.assigns.current_user.id),
       single_user_mode: Liteskill.SingleUser.enabled?(),
       mcp_servers: [],
       show_mcp_modal: false,
       mcp_form:
         to_form(%{"name" => "", "url" => "", "api_key" => "", "description" => "", "headers" => "", "global" => false},
           as: :mcp_server
         ),
       editing_mcp: nil,
       inspecting_server: nil,
       inspecting_tools: [],
       inspecting_tools_loading: false
     ), layout: {Layouts, :chat}}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    user_id = socket.assigns.current_user.id
    servers = McpServers.list_servers(user_id)

    {:noreply,
     assign(socket,
       mcp_servers: servers,
       show_mcp_modal: false,
       editing_mcp: nil,
       page_title: "Tools"
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen relative">
      <Layouts.sidebar
        sidebar_open={@sidebar_open}
        live_action={@live_action}
        conversations={@conversations}
        active_conversation_id={nil}
        current_user={@current_user}
        has_admin_access={@has_admin_access}
        single_user_mode={@single_user_mode}
      />

      <main class="flex-1 flex flex-col min-w-0">
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
              <h1 class="text-lg font-semibold">Tools</h1>
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
            <McpComponents.mcp_server_card
              :for={server <- @mcp_servers}
              server={server}
              owned={server.user_id == @current_user.id}
            />
          </div>
          <p
            :if={@mcp_servers == []}
            class="text-base-content/50 text-center py-12"
          >
            No tool servers configured yet. Click "Add Server" to get started.
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

            <div
              :if={match?(%Ecto.Changeset{action: a} when a != nil, @mcp_form.source)}
              class="alert alert-error text-sm"
            >
              <.icon name="hero-exclamation-circle" class="size-5 shrink-0" />
              <div>
                <p class="font-semibold">Could not save server:</p>
                <ul class="list-disc list-inside mt-1">
                  <li :for={
                    {field, msgs} <-
                      Ecto.Changeset.traverse_errors(@mcp_form.source, fn {msg, opts} ->
                        Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
                          opts
                          |> Keyword.get(String.to_existing_atom(key), key)
                          |> to_string()
                        end)
                      end)
                  }>
                    <span class="font-medium">{Phoenix.Naming.humanize(field)}:</span>
                    {Enum.join(msgs, ", ")}
                  </li>
                </ul>
              </div>
            </div>

            <.input
              field={@mcp_form[:name]}
              label="Name *"
              type="text"
              class="input input-bordered w-full"
              required
            />
            <.input
              field={@mcp_form[:url]}
              label="URL *"
              type="url"
              class="input input-bordered w-full"
              required
            />
            <.input
              field={@mcp_form[:api_key]}
              label="API Key"
              type="password"
              class="input input-bordered w-full"
              autocomplete="off"
            />
            <.input
              field={@mcp_form[:description]}
              label="Description"
              type="textarea"
              class="textarea textarea-bordered w-full"
              rows={2}
            />
            <div class="fieldset mb-2">
              <label>
                <span class="label mb-1">Custom Headers (JSON)</span>
                <textarea
                  name={@mcp_form[:headers].name}
                  class="textarea textarea-bordered w-full font-mono text-xs"
                  rows="3"
                  placeholder="{}"
                >{mcp_headers_value(@mcp_form[:headers].value)}</textarea>
              </label>
            </div>
            <.input
              field={@mcp_form[:global]}
              label="Share globally with all users"
              type="checkbox"
            />
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
      </main>
    </div>

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
        <McpComponents.tool_detail :for={tool <- @inspecting_tools} tool={tool} />
      </div>
    </ChatComponents.modal>
    """
  end

  # --- Event Handlers ---

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, sidebar_open: !socket.assigns.sidebar_open)}
  end

  @impl true
  def handle_event("select_conversation", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: "/c/#{id}")}
  end

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

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("load server", reason))}
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
        changeset = Map.put(changeset, :action, :validate)

        {:noreply, assign(socket, mcp_form: to_form(changeset, as: :mcp_server))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("save server", reason))}
    end
  end

  @impl true
  def handle_event("delete_mcp", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case McpServers.delete_server(id, user_id) do
      {:ok, _} ->
        servers = McpServers.list_servers(user_id)
        {:noreply, assign(socket, mcp_servers: servers)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("delete server", reason))}
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

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, action_error("update server status", reason))}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("load server", reason))}
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

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, action_error("load server", reason))}
    end
  end

  @impl true
  def handle_event("close_tools_modal", _params, socket) do
    {:noreply, assign(socket, inspecting_server: nil, inspecting_tools: [], inspecting_tools_loading: false)}
  end

  # --- handle_info callbacks ---

  @impl true
  def handle_info({:fetch_server_tools, %{builtin: module}}, socket) do
    tools = module.list_tools()
    {:noreply, assign(socket, inspecting_tools: tools, inspecting_tools_loading: false)}
  end

  @impl true
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

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Helpers ---

  defp parse_headers(str) when is_binary(str) do
    trimmed = String.trim(str)

    if trimmed == "" do
      %{}
    else
      case Jason.decode(trimmed) do
        {:ok, map} when is_map(map) -> map
        _ -> %{}
      end
    end
  end

  defp parse_headers(_), do: %{}

  defp mcp_headers_value(val) when is_map(val) and val != %{}, do: Jason.encode!(val, pretty: true)

  defp mcp_headers_value(val) when is_binary(val), do: val
  defp mcp_headers_value(_), do: ""

  defp format_tool_error(%{status: status, body: body}) when is_binary(body),
    do: "HTTP #{status}: #{String.slice(body, 0..100)}"

  defp format_tool_error(%{status: status}), do: "HTTP #{status}"
  defp format_tool_error(%Req.TransportError{reason: reason}), do: "Connection error: #{reason}"
  defp format_tool_error(reason) when is_binary(reason), do: reason
  defp format_tool_error(_reason), do: "unexpected error"
end
