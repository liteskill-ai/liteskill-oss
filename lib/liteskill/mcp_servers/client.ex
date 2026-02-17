defmodule Liteskill.McpServers.Client do
  @moduledoc """
  MCP JSON-RPC 2.0 HTTP client for Streamable HTTP transport.

  Implements the MCP initialization handshake (initialize → initialized → request)
  and supports `tools/list` and `tools/call` methods.
  Accepts a `plug:` option for testability with Req.Test.
  """

  @doc """
  Discover tools from an MCP server.

  Returns `{:ok, [tool]}` where each tool is a map with
  `"name"`, `"description"`, and `"inputSchema"` keys.
  """
  def list_tools(server, opts \\ []) do
    body = %{"jsonrpc" => "2.0", "method" => "tools/list", "id" => 1}

    case post(server, body, opts) do
      {:ok, %{"result" => %{"tools" => tools}}} ->
        {:ok, tools}

      {:ok, %{"error" => error}} ->
        {:error, error}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Call a tool on an MCP server.

  Returns `{:ok, result}` where result contains `"content"` from the server.
  """
  def call_tool(server, tool_name, arguments, opts \\ []) do
    body = %{
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "params" => %{"name" => tool_name, "arguments" => arguments},
      "id" => 1
    }

    case post(server, body, opts) do
      {:ok, %{"result" => result}} ->
        {:ok, result}

      {:ok, %{"error" => error}} ->
        {:error, error}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp post(server, body, opts) do
    with {:ok, session_id} <- initialize(server, opts) do
      send_initialized(server, session_id, opts)
      send_request(server, body, session_id, opts)
    end
  end

  defp initialize(server, opts) do
    body = %{
      "jsonrpc" => "2.0",
      "method" => "initialize",
      "id" => 0,
      "params" => %{
        "protocolVersion" => "2025-03-26",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "Liteskill", "version" => "1.0"}
      }
    }

    case do_post(server, body, nil, opts) do
      {:ok, %{status: 200, headers: headers}} ->
        {:ok, get_header(headers, "mcp-session-id")}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, %{status: status, body: resp_body}}

      # coveralls-ignore-next-line
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_initialized(server, session_id, opts) do
    body = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
    do_post(server, body, session_id, opts)
  end

  defp send_request(server, body, session_id, opts) do
    case do_post(server, body, session_id, opts) do
      {:ok, %{status: 200, body: resp_body}} ->
        {:ok, resp_body}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, %{status: status, body: resp_body}}

      # coveralls-ignore-next-line
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_post(server, body, session_id, opts) do
    req_opts = Keyword.take(opts, [:plug])

    all_opts =
      [
        url: server.url,
        json: body,
        headers: build_headers(server) ++ session_header(session_id)
      ] ++ req_opts

    case Req.post(Req.new(receive_timeout: 30_000), all_opts) do
      {:ok, resp} -> {:ok, %{resp | body: parse_body(resp.body)}}
      error -> error
    end
  end

  defp parse_body(body) when is_map(body), do: body

  defp parse_body(body) when is_binary(body) do
    data =
      body
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map_join("\n", fn line ->
        line |> String.trim_leading("data:") |> String.trim_leading()
      end)

    case Jason.decode(data) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  # coveralls-ignore-next-line
  defp parse_body(body), do: body

  defp session_header(nil), do: []
  defp session_header(session_id), do: [{"mcp-session-id", session_id}]

  defp get_header(headers, name) do
    case Map.get(headers, name) do
      [value | _] -> value
      _ -> nil
    end
  end

  @blocked_headers MapSet.new([
                     "authorization",
                     "host",
                     "content-type",
                     "content-length",
                     "transfer-encoding",
                     "connection",
                     "cookie",
                     "set-cookie",
                     "x-forwarded-for",
                     "x-forwarded-host",
                     "x-forwarded-proto",
                     "proxy-authorization"
                   ])

  defp build_headers(server) do
    base =
      if server.api_key && server.api_key != "" do
        [{"authorization", "Bearer #{server.api_key}"}]
      else
        []
      end

    custom =
      case server.headers do
        nil ->
          []

        h when h == %{} ->
          []

        h when is_map(h) ->
          h
          |> Enum.map(fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)
          |> Enum.reject(fn {k, v} ->
            MapSet.member?(@blocked_headers, k) or has_control_chars?(k) or has_control_chars?(v)
          end)
      end

    [{"content-type", "application/json"}, {"accept", "application/json, text/event-stream"}] ++
      base ++ custom
  end

  defp has_control_chars?(str) do
    String.contains?(str, ["\r", "\n", "\0"])
  end
end
