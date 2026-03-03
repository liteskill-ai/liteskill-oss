defmodule LiteskillWeb.FeatureCase do
  @moduledoc """
  Case template for Wallaby browser-based E2E tests.

  Tests using this case template are excluded from `mix test` by default
  and run via `mix test.e2e` (or `mix test --include e2e`).
  """
  use ExUnit.CaseTemplate
  use Wallaby.DSL

  alias Ecto.Adapters.SQL.Sandbox
  alias Liteskill.Accounts.User
  alias Liteskill.Repo

  using do
    quote do
      use Wallaby.DSL

      import LiteskillWeb.FeatureCase

      @moduletag :e2e
    end
  end

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})

    # Req.Test shared mode so server-side Req calls (e.g. OpenRouter.Models
    # in setup wizard mount) can find stubs registered by the test process.
    Req.Test.set_req_test_to_shared()

    Req.Test.stub(Liteskill.OpenRouter.Models, fn conn ->
      Plug.Conn.send_resp(conn, 200, Jason.encode!(%{"data" => []}))
    end)

    metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(Repo, self())
    {:ok, session} = Wallaby.start_session(metadata: metadata)
    on_exit(fn -> Wallaby.end_session(session) end)
    {:ok, session: session}
  end

  @doc "Register a new user via the browser registration form."
  def register_user(session, attrs \\ %{}) do
    name = Map.get(attrs, :name, "Test User")
    email = Map.get(attrs, :email, "e2e-#{System.unique_integer([:positive])}@example.com")
    password = Map.get(attrs, :password, "ValidPassword123!")

    session
    |> visit("/register")
    |> fill_in(Query.css("#user_name"), with: name)
    |> fill_in(Query.css("#user_email"), with: email)
    |> fill_in(Query.css("#user_password"), with: password)
    |> click(Query.button("Register"))

    %{session: session, name: name, email: email, password: password}
  end

  @doc "Log in an existing user via the browser login form."
  def login_user(session, email, password) do
    session
    |> visit("/login")
    |> fill_in(Query.css("#user_email"), with: email)
    |> fill_in(Query.css("#user_password"), with: password)
    |> click(Query.button("Sign In"))
  end

  @doc "Register a new user and return session + credentials."
  def register_and_login(session, attrs \\ %{}) do
    register_user(session, attrs)
  end

  @doc "Create a user directly in the database (without logging in via browser)."
  def create_user(attrs \\ %{}) do
    name = Map.get(attrs, :name, "Test User")
    email = Map.get(attrs, :email, "e2e-#{System.unique_integer([:positive])}@example.com")
    password = Map.get(attrs, :password, "ValidPassword123!")

    {:ok, user} =
      Liteskill.Accounts.register_user(%{name: name, email: email, password: password})

    %{user: user, name: name, email: email, password: password}
  end

  @doc """
  Create the admin user with no password, triggering `User.setup_required?/1`.

  This makes `/setup` accessible via the `:require_setup_needed` live session.
  Returns the admin user struct.
  """
  def create_setup_admin do
    Repo.insert!(%User{
      email: User.admin_email(),
      name: "Admin",
      role: "admin",
      password_hash: nil
    })
  end

  @doc """
  Set a mock stream function for E2E LLM testing.

  The function emits `response_text` one grapheme at a time through `on_chunk`,
  then returns a successful result. Automatically cleaned up via `on_exit`.
  """
  def mock_llm_stream(response_text) do
    stream_fn = fn _model_id, _messages, on_chunk, _opts ->
      response_text |> String.graphemes() |> Enum.each(&on_chunk.(&1))
      {:ok, response_text, [], %{input_tokens: 10, output_tokens: String.length(response_text)}}
    end

    Application.put_env(:liteskill, :e2e_stream_fn, stream_fn)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:liteskill, :e2e_stream_fn) end)
  end

  @doc """
  Mock a multi-round LLM conversation with tool calls.

  Each round is a map with:
  - `:text` — assistant text to stream (default "")
  - `:tool_calls` — list of normalized tool call maps (default [])

  `builtin_modules` is a list of builtin tool modules (e.g. `[Liteskill.BuiltinTools.Wiki]`)
  whose tools will be available for execution with `auto_confirm: true`.

  Uses an Agent to track which round to serve. Automatically cleaned up via `on_exit`.
  """
  def mock_llm_tool_stream(rounds, builtin_modules) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    stream_fn = fn _model_id, _messages, on_chunk, _opts ->
      idx = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      round = Enum.at(rounds, idx, List.last(rounds))
      text = round[:text] || ""
      tool_calls = round[:tool_calls] || []
      text |> String.graphemes() |> Enum.each(&on_chunk.(&1))
      {:ok, text, tool_calls, %{input_tokens: 10, output_tokens: String.length(text)}}
    end

    {bedrock_tools, tool_servers} = build_builtin_tool_config(builtin_modules)

    extra_opts = [
      stream_fn: stream_fn,
      tools: bedrock_tools,
      tool_servers: tool_servers,
      auto_confirm: true
    ]

    Application.put_env(:liteskill, :e2e_stream_fn, extra_opts)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:liteskill, :e2e_stream_fn)
      if Process.alive?(counter), do: Agent.stop(counter)
    end)
  end

  @doc """
  Mock a multi-round LLM conversation that calls MCP server tools.

  Like `mock_llm_tool_stream/2` but routes tool execution through a real
  `%McpServer{}` struct (which hits the `Req.Test` stub) instead of builtin modules.

  - `rounds` — list of `%{text: "...", tool_calls: [...]}` maps
  - `server` — a `%McpServer{}` struct (from the DB)
  - `tool_specs` — list of MCP tool spec maps (same format as `tools/list` result)
  """
  def mock_mcp_tool_stream(rounds, server, tool_specs) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    stream_fn = fn _model_id, _messages, on_chunk, _opts ->
      idx = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      round = Enum.at(rounds, idx, List.last(rounds))
      text = round[:text] || ""
      tool_calls = round[:tool_calls] || []
      text |> String.graphemes() |> Enum.each(&on_chunk.(&1))
      {:ok, text, tool_calls, %{input_tokens: 10, output_tokens: String.length(text)}}
    end

    bedrock_tools =
      Enum.map(tool_specs, fn tool ->
        %{
          "toolSpec" => %{
            "name" => tool["name"],
            "description" => tool["description"] || "",
            "inputSchema" => %{"json" => tool["inputSchema"] || %{}}
          }
        }
      end)

    tool_servers = Map.new(tool_specs, fn tool -> {tool["name"], server} end)

    extra_opts = [
      stream_fn: stream_fn,
      tools: bedrock_tools,
      tool_servers: tool_servers,
      auto_confirm: true
    ]

    Application.put_env(:liteskill, :e2e_stream_fn, extra_opts)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:liteskill, :e2e_stream_fn)
      if Process.alive?(counter), do: Agent.stop(counter)
    end)
  end

  @doc """
  Stub the MCP JSON-RPC client for E2E tests.

  Handles the full handshake (initialize → initialized) plus `tools/list`
  and `tools/call` methods. `tool_results` is a map of `tool_name => result_map`
  with a default fallback for unspecified tools.
  """
  def stub_mcp_client(tool_specs, tool_results \\ %{}) do
    Req.Test.stub(Liteskill.McpServers.Client, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)

      case decoded["method"] do
        "initialize" ->
          resp = %{
            "jsonrpc" => "2.0",
            "result" => %{
              "protocolVersion" => "2025-03-26",
              "capabilities" => %{},
              "serverInfo" => %{"name" => "E2E Mock MCP", "version" => "1.0"}
            },
            "id" => 0
          }

          conn
          |> Plug.Conn.put_resp_header("mcp-session-id", "e2e-session-#{System.unique_integer([:positive])}")
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(resp))

        "notifications/initialized" ->
          Plug.Conn.send_resp(conn, 200, "")

        "tools/list" ->
          resp = %{"jsonrpc" => "2.0", "result" => %{"tools" => tool_specs}, "id" => 1}

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(resp))

        "tools/call" ->
          tool_name = get_in(decoded, ["params", "name"])

          result =
            Map.get(tool_results, tool_name, %{
              "content" => [%{"type" => "text", "text" => "Mock result for #{tool_name}"}]
            })

          resp = %{"jsonrpc" => "2.0", "result" => result, "id" => 1}

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end
    end)
  end

  defp build_builtin_tool_config(modules) do
    Enum.reduce(modules, {[], %{}}, fn module, {tools_acc, servers_acc} ->
      server = %{builtin: module}

      new_tools =
        Enum.map(module.list_tools(), fn tool ->
          %{
            "toolSpec" => %{
              "name" => tool["name"],
              "description" => tool["description"] || "",
              "inputSchema" => %{"json" => tool["inputSchema"] || %{}}
            }
          }
        end)

      new_servers = Map.new(module.list_tools(), fn tool -> {tool["name"], server} end)
      {tools_acc ++ new_tools, Map.merge(servers_acc, new_servers)}
    end)
  end
end
