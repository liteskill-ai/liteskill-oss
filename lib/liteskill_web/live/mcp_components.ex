defmodule LiteskillWeb.McpComponents do
  @moduledoc """
  Function components for MCP server and tool call UI.
  """

  use Phoenix.Component

  import LiteskillWeb.CoreComponents, only: [icon: 1]

  attr :server, :map, required: true
  attr :owned, :boolean, required: true

  def mcp_server_card(assigns) do
    assigns = assign(assigns, :builtin?, Map.has_key?(assigns.server, :builtin))

    ~H"""
    <div class="card bg-base-100 border border-base-300 shadow-sm">
      <div class="card-body p-4">
        <div class="flex items-start justify-between gap-2">
          <div class="flex-1 min-w-0">
            <h3 class="font-semibold text-sm truncate">{@server.name}</h3>
            <p :if={@server.url} class="text-xs text-base-content/60 truncate mt-0.5">
              {@server.url}
            </p>
          </div>
          <div class="flex items-center gap-1">
            <span :if={!@builtin?} class="badge badge-sm badge-accent">MCP</span>
            <span :if={@builtin?} class="badge badge-sm badge-primary">built-in</span>
            <span class={[
              "badge badge-sm",
              if(@server.status == "active", do: "badge-success", else: "badge-ghost")
            ]}>
              {@server.status}
            </span>
          </div>
        </div>
        <p :if={@server.description} class="text-xs text-base-content/70 mt-1 line-clamp-2">
          {@server.description}
        </p>
        <div :if={!@builtin? && @server.global} class="flex items-center gap-1 mt-2">
          <span class="badge badge-xs badge-info">global</span>
        </div>
        <div class="card-actions justify-end mt-2">
          <div class="dropdown dropdown-end">
            <div tabindex="0" role="button" class="btn btn-ghost btn-xs gap-1">
              <.icon name="hero-ellipsis-horizontal-micro" class="size-4" /> Actions
            </div>
            <ul
              tabindex="0"
              class="dropdown-content menu menu-sm bg-base-200 rounded-lg shadow-lg z-10 w-40 p-1"
            >
              <li>
                <button phx-click="inspect_tools" phx-value-id={@server.id}>
                  <.icon name="hero-code-bracket-micro" class="size-4" /> Tools
                </button>
              </li>
              <li :if={@owned && !@builtin?}>
                <button
                  phx-click="open_sharing"
                  phx-value-entity-type="mcp_server"
                  phx-value-entity-id={@server.id}
                >
                  <.icon name="hero-share-micro" class="size-4" /> Share
                </button>
              </li>
              <li :if={@owned && !@builtin?}>
                <button phx-click="edit_mcp" phx-value-id={@server.id}>
                  <.icon name="hero-pencil-square-micro" class="size-4" /> Edit
                </button>
              </li>
              <li :if={@owned && !@builtin?}>
                <button
                  phx-click="delete_mcp"
                  phx-value-id={@server.id}
                  data-confirm="Delete this server?"
                  class="text-error"
                >
                  <.icon name="hero-trash-micro" class="size-4" /> Delete
                </button>
              </li>
            </ul>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :available_tools, :list, required: true
  attr :selected_server_ids, :any, required: true
  attr :show, :boolean, required: true
  attr :auto_confirm, :boolean, required: true
  attr :tools_loading, :boolean, default: false
  attr :prefix, :string, default: ""
  attr :direction, :string, default: "up"

  def server_picker(assigns) do
    servers =
      assigns.available_tools
      |> Enum.group_by(& &1.server_id)
      |> Enum.map(fn {server_id, tools} ->
        first = hd(tools)

        %{
          id: server_id,
          name: first.server_name,
          tool_count: length(tools),
          source: Map.get(first, :source, :builtin)
        }
      end)

    assigns =
      assign(assigns,
        selected_count: MapSet.size(assigns.selected_server_ids),
        servers: servers
      )

    ~H"""
    <div class="relative">
      <button
        type="button"
        phx-click={"#{@prefix}toggle_tool_picker"}
        class={[
          "btn btn-ghost btn-sm m-1 gap-1",
          if(@selected_count > 0, do: "text-primary", else: "text-base-content/50")
        ]}
      >
        <.icon name="hero-wrench-screwdriver-micro" class="size-4" />
        <span :if={@selected_count > 0} class="badge badge-primary badge-xs">
          {@selected_count}
        </span>
      </button>

      <div
        :if={@show}
        class={[
          "absolute left-0 w-72 bg-base-100 border border-base-300 rounded-xl shadow-lg z-50 max-h-96 overflow-y-auto",
          if(@direction == "up", do: "bottom-full mb-2", else: "top-full mt-2")
        ]}
        phx-click-away={"#{@prefix}toggle_tool_picker"}
      >
        <div class="p-3 border-b border-base-300 flex items-center justify-between">
          <span class="text-sm font-semibold">Tool Servers</span>
          <button
            :if={@selected_count > 0}
            type="button"
            phx-click={"#{@prefix}clear_tools"}
            class="btn btn-ghost btn-xs text-base-content/50"
          >
            Clear
          </button>
        </div>

        <div :if={@tools_loading} class="p-4 text-center text-sm text-base-content/50">
          Loading servers...
        </div>

        <div
          :if={!@tools_loading && @servers == []}
          class="p-4 text-center text-sm text-base-content/50"
        >
          <p>No tool servers found</p>
          <button
            type="button"
            phx-click={"#{@prefix}refresh_tools"}
            class="btn btn-ghost btn-xs mt-2 gap-1"
          >
            <.icon name="hero-arrow-path-micro" class="size-3" /> Retry
          </button>
        </div>

        <div :if={!@tools_loading && @servers != []} class="py-1">
          <div
            :for={server <- @servers}
            class="flex items-center gap-2 px-3 py-2 hover:bg-base-200"
          >
            <label class="flex items-center gap-2 flex-1 min-w-0 cursor-pointer">
              <input
                type="checkbox"
                phx-click={"#{@prefix}toggle_server"}
                phx-value-server-id={server.id}
                checked={MapSet.member?(@selected_server_ids, server.id)}
                class="checkbox checkbox-sm checkbox-primary"
              />
              <div class="flex-1 min-w-0">
                <div class="text-sm font-medium truncate flex items-center gap-1">
                  {server.name}
                  <span :if={server.source == :mcp} class="badge badge-xs badge-accent">MCP</span>
                </div>
                <div class="text-xs text-base-content/60">
                  {server.tool_count} {if server.tool_count == 1, do: "tool", else: "tools"}
                </div>
              </div>
            </label>
            <button
              type="button"
              phx-click="inspect_tools"
              phx-value-id={server.id}
              class="text-base-content/40 hover:text-info"
            >
              <.icon name="hero-information-circle-micro" class="size-4" />
            </button>
          </div>
        </div>

        <div class="p-3 border-t border-base-300">
          <label class="flex items-center gap-2 cursor-pointer">
            <input
              type="checkbox"
              phx-click={"#{@prefix}toggle_auto_confirm"}
              checked={@auto_confirm}
              class="toggle toggle-xs toggle-primary"
            />
            <span class="text-xs text-base-content/70">Auto-confirm tool calls</span>
          </label>
        </div>
      </div>
    </div>
    """
  end

  attr :tool_call, :map, required: true
  attr :show_actions, :boolean, default: false

  def tool_call_display(assigns) do
    {server_name, tool_name} = split_tool_name(assigns.tool_call.tool_name)
    assigns = assign(assigns, server_name: server_name, display_tool_name: tool_name)

    ~H"""
    <div class="flex items-center justify-start mb-2 gap-2">
      <div
        class="inline-flex items-center gap-2 bg-base-200/50 border border-base-300 rounded-lg px-3 py-1.5 text-xs cursor-pointer hover:bg-base-200 transition-colors"
        phx-click="show_tool_call"
        phx-value-tool-use-id={@tool_call.tool_use_id}
      >
        <.icon name="hero-wrench-screwdriver-micro" class="size-3.5 text-base-content/50 shrink-0" />
        <span :if={@server_name != ""} class="text-base-content/70">{@server_name}</span>
        <code class="bg-base-300/60 px-1 py-0.5 rounded text-[0.7rem]">{@display_tool_name}</code>
        <span class={[
          "badge badge-xs",
          case @tool_call.status do
            "started" -> "badge-warning"
            "completed" -> "badge-success"
            _ -> "badge-ghost"
          end
        ]}>
          {@tool_call.status}
        </span>
        <span
          :if={@tool_call.status == "completed" && @tool_call.duration_ms}
          class="text-[0.65rem] italic text-base-content/40"
        >
          Ran for: {format_duration_ms(@tool_call.duration_ms)}
        </span>
      </div>
      <div :if={@show_actions && @tool_call.status == "started"} class="flex gap-1 items-center">
        <button
          phx-click="approve_tool_call"
          phx-value-tool-use-id={@tool_call.tool_use_id}
          class="btn btn-success btn-xs gap-1"
        >
          <.icon name="hero-check-micro" class="size-3" /> Approve
        </button>
        <button
          phx-click="reject_tool_call"
          phx-value-tool-use-id={@tool_call.tool_use_id}
          class="btn btn-error btn-xs gap-1"
        >
          <.icon name="hero-x-mark-micro" class="size-3" /> Reject
        </button>
      </div>
    </div>
    """
  end

  attr :tool_call, :map, default: nil

  def tool_call_modal(assigns) do
    {server_name, tool_name} =
      if assigns.tool_call, do: split_tool_name(assigns.tool_call.tool_name), else: {"", ""}

    {input_type, input_data} =
      if assigns.tool_call, do: prepare_output(assigns.tool_call.input), else: {:text, ""}

    {output_type, output_data} =
      if assigns.tool_call, do: prepare_output(assigns.tool_call.output), else: {:text, ""}

    assigns =
      assign(assigns,
        server_name: server_name,
        display_tool_name: tool_name,
        input_type: input_type,
        input_data: input_data,
        output_type: output_type,
        output_data: output_data
      )

    ~H"""
    <div
      :if={@tool_call}
      class="fixed inset-0 z-50 flex items-center justify-center"
      phx-window-keydown="close_tool_call_modal"
      phx-key="Escape"
    >
      <div class="fixed inset-0 bg-black/50" phx-click="close_tool_call_modal" />
      <div class="relative bg-base-100 rounded-xl shadow-xl w-full max-w-2xl mx-4 max-h-[85vh] overflow-y-auto z-10">
        <div class="flex items-center justify-between p-4 border-b border-base-300">
          <div class="flex items-center gap-2">
            <.icon name="hero-wrench-screwdriver-micro" class="size-4 text-base-content/50" />
            <span :if={@server_name != ""} class="text-sm text-base-content/70">{@server_name}</span>
            <code class="bg-base-300/60 px-1.5 py-0.5 rounded text-sm">{@display_tool_name}</code>
            <span class={[
              "badge badge-sm",
              case @tool_call.status do
                "started" -> "badge-warning"
                "completed" -> "badge-success"
                _ -> "badge-ghost"
              end
            ]}>
              {@tool_call.status}
            </span>
          </div>
          <button phx-click="close_tool_call_modal" class="btn btn-ghost btn-sm btn-square">
            <.icon name="hero-x-mark-micro" class="size-5" />
          </button>
        </div>
        <div class="p-4 space-y-4">
          <div :if={@tool_call.input && @tool_call.input != %{}}>
            <div class="flex items-center gap-2 mb-2">
              <h4 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider">
                Input
              </h4>
              <span class={[
                "badge badge-xs",
                case @input_type do
                  :json -> "badge-info"
                  :markdown -> "badge-secondary"
                  :text -> "badge-ghost"
                end
              ]}>
                {output_type_label(@input_type)}
              </span>
            </div>
            <.json_viewer :if={@input_type == :json} data={@input_data} />
            <div
              :if={@input_type == :markdown}
              class="p-3 bg-base-200 rounded-lg max-h-[50vh] overflow-y-auto prose prose-sm max-w-none"
            >
              {LiteskillWeb.Markdown.render(@input_data)}
            </div>
            <pre
              :if={@input_type == :text}
              class="p-3 bg-base-200 rounded-lg text-xs overflow-x-auto whitespace-pre-wrap max-h-[50vh]"
            ><code>{@input_data}</code></pre>
          </div>
          <div :if={@tool_call.output}>
            <div class="flex items-center gap-2 mb-2">
              <h4 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider">
                Output
              </h4>
              <span class={[
                "badge badge-xs",
                case @output_type do
                  :json -> "badge-info"
                  :markdown -> "badge-secondary"
                  :text -> "badge-ghost"
                end
              ]}>
                {output_type_label(@output_type)}
              </span>
            </div>
            <.json_viewer :if={@output_type == :json} data={@output_data} />
            <div
              :if={@output_type == :markdown}
              class="p-3 bg-base-200 rounded-lg max-h-[50vh] overflow-y-auto prose prose-sm max-w-none"
            >
              {LiteskillWeb.Markdown.render(@output_data)}
            </div>
            <pre
              :if={@output_type == :text}
              class="p-3 bg-base-200 rounded-lg text-xs overflow-x-auto whitespace-pre-wrap max-h-[50vh]"
            ><code>{@output_data}</code></pre>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :data, :any, required: true

  def json_viewer(assigns) do
    ~H"""
    <div data-json-viewer class="bg-base-200 rounded-lg max-h-[50vh] overflow-y-auto">
      <div class="flex justify-end gap-1 px-3 pt-2 sticky top-0 bg-base-200 z-10">
        <button
          type="button"
          class="btn btn-ghost btn-xs text-base-content/50"
          onclick="this.closest('[data-json-viewer]').querySelectorAll('details').forEach(d => d.open = true)"
        >
          Expand all
        </button>
        <button
          type="button"
          class="btn btn-ghost btn-xs text-base-content/50"
          onclick="this.closest('[data-json-viewer]').querySelectorAll('details').forEach(d => d.open = false)"
        >
          Collapse all
        </button>
      </div>
      <div class="p-3 pt-1 overflow-x-auto">
        <.json_tree data={@data} />
      </div>
    </div>
    """
  end

  attr :data, :any, required: true
  attr :depth, :integer, default: 0

  def json_tree(%{data: data} = assigns) when is_map(data) do
    assigns = assign(assigns, :entries, Enum.sort_by(data, &elem(&1, 0)))

    ~H"""
    <div class={if @depth > 0, do: "ml-4 border-l border-base-300/50 pl-2"}>
      <div :for={{key, value} <- @entries} class="py-0.5 text-xs leading-relaxed">
        <%= if is_map(value) or is_list(value) do %>
          <details open={@depth < 1}>
            <summary class="cursor-pointer select-none hover:bg-base-200/50 rounded px-1 -mx-1">
              <span class="text-info font-medium">{key}</span><span class="text-base-content/40">: {type_hint(value)}</span>
            </summary>
            <.json_tree data={value} depth={@depth + 1} />
          </details>
        <% else %>
          <div class="px-1">
            <span class="text-info font-medium">{key}</span><span class="text-base-content/40">: </span>
            <.json_value data={value} />
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  def json_tree(%{data: data} = assigns) when is_list(data) do
    assigns = assign(assigns, :items, Enum.with_index(data))

    ~H"""
    <div class={if @depth > 0, do: "ml-4 border-l border-base-300/50 pl-2"}>
      <div :for={{item, idx} <- @items} class="py-0.5 text-xs leading-relaxed">
        <%= if is_map(item) or is_list(item) do %>
          <details open={@depth < 1}>
            <summary class="cursor-pointer select-none hover:bg-base-200/50 rounded px-1 -mx-1">
              <span class="text-base-content/40">[{idx}]: {type_hint(item)}</span>
            </summary>
            <.json_tree data={item} depth={@depth + 1} />
          </details>
        <% else %>
          <div class="px-1">
            <span class="text-base-content/40">[{idx}]: </span> <.json_value data={item} />
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  def json_tree(assigns) do
    ~H"<.json_value data={@data} />"
  end

  attr :data, :any, required: true

  def json_value(%{data: data} = assigns) when is_binary(data) do
    ~H"""
    <span class="text-success break-all">"{@data}"</span>
    """
  end

  def json_value(%{data: data} = assigns) when is_number(data) do
    ~H[<span class="text-warning">{@data}</span>]
  end

  def json_value(%{data: true} = assigns) do
    ~H[<span class="text-accent">true</span>]
  end

  def json_value(%{data: false} = assigns) do
    ~H[<span class="text-accent">false</span>]
  end

  def json_value(%{data: nil} = assigns) do
    ~H[<span class="text-base-content/40 italic">null</span>]
  end

  def json_value(assigns) do
    ~H"<span>{inspect(@data)}</span>"
  end

  defp split_tool_name(name) do
    case String.split(name, "__", parts: 2) do
      [server, tool] ->
        display_server =
          server
          |> String.replace("_", " ")
          |> String.split(" ")
          |> Enum.map_join(" ", &String.capitalize/1)

        {display_server, tool}

      [_tool] ->
        {"", name}
    end
  end

  defp format_duration_ms(ms) when is_integer(ms) and ms < 1000, do: "#{ms}ms"

  defp format_duration_ms(ms) when is_integer(ms) and ms < 60_000 do
    seconds = ms / 1000
    :erlang.float_to_binary(seconds, decimals: 2) <> " seconds"
  end

  defp format_duration_ms(ms) when is_integer(ms) do
    total_sec = div(ms, 1000)
    m = div(total_sec, 60)
    s = rem(total_sec, 60)
    "#{m}m #{s}s"
  end

  defp format_duration_ms(_), do: ""

  defp prepare_output(nil), do: {:text, ""}

  defp prepare_output(%{"content" => content}) when is_list(content) do
    text =
      Enum.map_join(content, "\n", fn
        %{"text" => text} -> text
        other -> Jason.encode!(other, pretty: true)
      end)

    detect_text_type(text)
  end

  defp prepare_output(output) when is_map(output), do: {:json, output}
  defp prepare_output(output) when is_list(output), do: {:json, output}
  defp prepare_output(output) when is_binary(output), do: detect_text_type(output)
  defp prepare_output(output), do: {:text, inspect(output)}

  defp detect_text_type(text) do
    case Jason.decode(text) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) ->
        {:json, decoded}

      _ ->
        if markdown_text?(text), do: {:markdown, text}, else: {:text, text}
    end
  end

  defp markdown_text?(text) do
    String.contains?(text, "```") or
      String.contains?(text, "**") or
      Regex.match?(~r/^\#{1,6}\s/m, text) or
      Regex.match?(~r/\[.+?\]\(.+?\)/, text) or
      Regex.match?(~r/^\s*[-*+]\s/m, text) or
      Regex.match?(~r/^\|.+\|$/m, text)
  end

  defp output_type_label(:json), do: "JSON"
  defp output_type_label(:markdown), do: "Markdown"
  defp output_type_label(:text), do: "Text"

  defp type_hint(data) when is_map(data), do: "{#{map_size(data)}}"
  defp type_hint(data) when is_list(data), do: "[#{length(data)}]"
  defp type_hint(_), do: ""

  attr :available_tools, :list, required: true
  attr :selected_server_ids, :any, required: true
  attr :prefix, :string, default: ""

  def selected_server_badges(assigns) do
    selected_servers =
      assigns.available_tools
      |> Enum.group_by(& &1.server_id)
      |> Enum.filter(fn {server_id, _} ->
        MapSet.member?(assigns.selected_server_ids, server_id)
      end)
      |> Enum.map(fn {server_id, tools} ->
        first = hd(tools)
        %{id: server_id, name: first.server_name, source: Map.get(first, :source, :builtin)}
      end)

    assigns = assign(assigns, selected_servers: selected_servers)

    ~H"""
    <div :if={@selected_servers != []} class="flex flex-wrap gap-1 px-1 pb-1">
      <span
        :for={server <- @selected_servers}
        class="badge badge-sm badge-outline badge-primary gap-1"
      >
        {server.name}
        <span :if={server.source == :mcp} class="badge badge-xs badge-accent">MCP</span>
        <button
          type="button"
          phx-click={"#{@prefix}toggle_server"}
          phx-value-server-id={server.id}
          class="hover:text-error"
        >
          <.icon name="hero-x-mark-micro" class="size-3" />
        </button>
      </span>
    </div>
    """
  end

  attr :tool, :map, required: true

  def tool_detail(assigns) do
    properties = get_in(assigns.tool, ["inputSchema", "properties"]) || %{}
    required_fields = get_in(assigns.tool, ["inputSchema", "required"]) || []

    params =
      Enum.map(properties, fn {name, schema} ->
        %{
          name: name,
          type: schema["type"] || "any",
          description: schema["description"],
          required: name in required_fields
        }
      end)
      |> Enum.sort_by(&(!&1.required))

    assigns = assign(assigns, params: params)

    ~H"""
    <div class="collapse collapse-arrow border border-base-300 bg-base-200/30 rounded-lg">
      <input type="checkbox" />
      <div class="collapse-title py-2 px-3 min-h-0">
        <span class="font-mono text-sm font-semibold">{@tool["name"]}</span>
      </div>
      <div class="collapse-content px-3 pb-3 text-xs">
        <p :if={@tool["description"]} class="text-base-content/70 mb-3">
          {@tool["description"]}
        </p>
        <div :if={@params != []} class="space-y-2">
          <h4 class="font-semibold text-base-content/80">Parameters</h4>
          <div :for={param <- @params} class="flex flex-col gap-0.5 pl-2 border-l-2 border-base-300">
            <div class="flex items-center gap-2">
              <code class="text-primary font-semibold">{param.name}</code>
              <span class="badge badge-xs badge-ghost">{param.type}</span>
              <span :if={param.required} class="badge badge-xs badge-warning">required</span>
            </div>
            <p :if={param.description} class="text-base-content/60">{param.description}</p>
          </div>
        </div>
        <p :if={@params == []} class="text-base-content/50 italic">No parameters</p>
      </div>
    </div>
    """
  end
end
