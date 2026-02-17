defmodule Liteskill.McpServers.ClientTest do
  use ExUnit.Case, async: true

  alias Liteskill.McpServers.Client

  defp build_server(overrides \\ %{}) do
    defaults = %{
      url: "https://mcp.example.com/rpc",
      api_key: nil,
      headers: %{}
    }

    Map.merge(defaults, overrides)
  end

  defp init_response(conn) do
    resp = %{
      "jsonrpc" => "2.0",
      "result" => %{
        "protocolVersion" => "2025-03-26",
        "capabilities" => %{},
        "serverInfo" => %{"name" => "test", "version" => "1.0"}
      },
      "id" => 0
    }

    conn
    |> Plug.Conn.put_resp_header("mcp-session-id", "test-session")
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(resp))
  end

  defp stub_with_init(handler) do
    Req.Test.stub(Liteskill.McpServers.Client, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)

      case decoded["method"] do
        "initialize" -> init_response(conn)
        "notifications/initialized" -> Plug.Conn.send_resp(conn, 200, "")
        _ -> handler.(conn, decoded)
      end
    end)
  end

  describe "list_tools/2" do
    test "returns tools on success" do
      server = build_server()

      stub_with_init(fn conn, decoded ->
        assert decoded["jsonrpc"] == "2.0"
        assert decoded["method"] == "tools/list"
        assert decoded["id"] == 1

        resp = %{
          "jsonrpc" => "2.0",
          "result" => %{
            "tools" => [
              %{
                "name" => "get_weather",
                "description" => "Get weather for a location",
                "inputSchema" => %{
                  "type" => "object",
                  "properties" => %{
                    "location" => %{"type" => "string"}
                  }
                }
              }
            ]
          },
          "id" => 1
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end)

      assert {:ok, tools} =
               Client.list_tools(server, plug: {Req.Test, Liteskill.McpServers.Client})

      assert length(tools) == 1
      assert hd(tools)["name"] == "get_weather"
      assert hd(tools)["description"] == "Get weather for a location"
    end

    test "returns error on JSON-RPC error" do
      server = build_server()

      stub_with_init(fn conn, _decoded ->
        resp = %{
          "jsonrpc" => "2.0",
          "error" => %{"code" => -32_601, "message" => "Method not found"},
          "id" => 1
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end)

      assert {:error, %{"code" => -32_601}} =
               Client.list_tools(server, plug: {Req.Test, Liteskill.McpServers.Client})
    end

    test "returns error on HTTP failure during initialization" do
      server = build_server()

      Req.Test.stub(Liteskill.McpServers.Client, fn conn ->
        conn
        |> Plug.Conn.send_resp(500, "Internal Server Error")
      end)

      assert {:error, %{status: 500}} =
               Client.list_tools(server, plug: {Req.Test, Liteskill.McpServers.Client})
    end

    test "returns error on HTTP failure after successful initialization" do
      server = build_server()

      stub_with_init(fn conn, _decoded ->
        conn
        |> Plug.Conn.send_resp(500, "Internal Server Error")
      end)

      assert {:error, %{status: 500}} =
               Client.list_tools(server, plug: {Req.Test, Liteskill.McpServers.Client})
    end

    test "returns empty list when server has no tools" do
      server = build_server()

      stub_with_init(fn conn, _decoded ->
        resp = %{
          "jsonrpc" => "2.0",
          "result" => %{"tools" => []},
          "id" => 1
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end)

      assert {:ok, []} =
               Client.list_tools(server, plug: {Req.Test, Liteskill.McpServers.Client})
    end
  end

  describe "call_tool/4" do
    test "returns result on success" do
      server = build_server()

      stub_with_init(fn conn, decoded ->
        assert decoded["jsonrpc"] == "2.0"
        assert decoded["method"] == "tools/call"
        assert decoded["params"]["name"] == "get_weather"
        assert decoded["params"]["arguments"] == %{"location" => "NYC"}

        resp = %{
          "jsonrpc" => "2.0",
          "result" => %{
            "content" => [%{"type" => "text", "text" => "Sunny, 72F"}]
          },
          "id" => 1
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end)

      assert {:ok, result} =
               Client.call_tool(
                 server,
                 "get_weather",
                 %{"location" => "NYC"},
                 plug: {Req.Test, Liteskill.McpServers.Client}
               )

      assert result["content"] == [%{"type" => "text", "text" => "Sunny, 72F"}]
    end

    test "returns error on JSON-RPC error" do
      server = build_server()

      stub_with_init(fn conn, _decoded ->
        resp = %{
          "jsonrpc" => "2.0",
          "error" => %{"code" => -32_602, "message" => "Invalid params"},
          "id" => 1
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end)

      assert {:error, %{"code" => -32_602}} =
               Client.call_tool(
                 server,
                 "bad_tool",
                 %{},
                 plug: {Req.Test, Liteskill.McpServers.Client}
               )
    end

    test "returns error on HTTP failure during initialization" do
      server = build_server()

      Req.Test.stub(Liteskill.McpServers.Client, fn conn ->
        conn
        |> Plug.Conn.send_resp(502, "Bad Gateway")
      end)

      assert {:error, %{status: 502}} =
               Client.call_tool(
                 server,
                 "some_tool",
                 %{},
                 plug: {Req.Test, Liteskill.McpServers.Client}
               )
    end
  end

  describe "initialization" do
    test "sends initialize request with correct protocol version" do
      server = build_server()

      Req.Test.stub(Liteskill.McpServers.Client, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        case decoded["method"] do
          "initialize" ->
            assert decoded["params"]["protocolVersion"] == "2025-03-26"
            assert decoded["params"]["clientInfo"]["name"] == "Liteskill"
            init_response(conn)

          "notifications/initialized" ->
            Plug.Conn.send_resp(conn, 200, "")

          _ ->
            resp = %{"jsonrpc" => "2.0", "result" => %{"tools" => []}, "id" => 1}

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(resp))
        end
      end)

      assert {:ok, []} =
               Client.list_tools(server, plug: {Req.Test, Liteskill.McpServers.Client})
    end

    test "works when server does not return a session ID" do
      server = build_server()

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
                "serverInfo" => %{"name" => "test", "version" => "1.0"}
              },
              "id" => 0
            }

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(resp))

          "notifications/initialized" ->
            Plug.Conn.send_resp(conn, 200, "")

          _ ->
            resp = %{"jsonrpc" => "2.0", "result" => %{"tools" => []}, "id" => 1}

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(resp))
        end
      end)

      assert {:ok, []} =
               Client.list_tools(server, plug: {Req.Test, Liteskill.McpServers.Client})
    end

    test "includes session ID in subsequent requests" do
      server = build_server()

      Req.Test.stub(Liteskill.McpServers.Client, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        case decoded["method"] do
          "initialize" ->
            init_response(conn)

          "notifications/initialized" ->
            session =
              conn.req_headers
              |> Enum.find(fn {k, _} -> k == "mcp-session-id" end)

            assert session == {"mcp-session-id", "test-session"}
            Plug.Conn.send_resp(conn, 200, "")

          "tools/list" ->
            session =
              conn.req_headers
              |> Enum.find(fn {k, _} -> k == "mcp-session-id" end)

            assert session == {"mcp-session-id", "test-session"}

            resp = %{"jsonrpc" => "2.0", "result" => %{"tools" => []}, "id" => 1}

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(resp))
        end
      end)

      assert {:ok, []} =
               Client.list_tools(server, plug: {Req.Test, Liteskill.McpServers.Client})
    end
  end

  describe "SSE response parsing" do
    test "parses SSE text/event-stream responses" do
      server = build_server()

      Req.Test.stub(Liteskill.McpServers.Client, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        case decoded["method"] do
          "initialize" ->
            sse_body =
              "event: message\ndata: " <>
                Jason.encode!(%{
                  "jsonrpc" => "2.0",
                  "result" => %{
                    "protocolVersion" => "2025-03-26",
                    "capabilities" => %{},
                    "serverInfo" => %{"name" => "test", "version" => "1.0"}
                  },
                  "id" => 0
                }) <> "\n\n"

            conn
            |> Plug.Conn.put_resp_header("mcp-session-id", "sse-session")
            |> Plug.Conn.put_resp_content_type("text/event-stream")
            |> Plug.Conn.send_resp(200, sse_body)

          "notifications/initialized" ->
            Plug.Conn.send_resp(conn, 200, "")

          "tools/list" ->
            sse_body =
              "event: message\ndata: " <>
                Jason.encode!(%{
                  "jsonrpc" => "2.0",
                  "result" => %{
                    "tools" => [
                      %{
                        "name" => "sse_tool",
                        "description" => "A tool from SSE",
                        "inputSchema" => %{"type" => "object"}
                      }
                    ]
                  },
                  "id" => 1
                }) <> "\n\n"

            conn
            |> Plug.Conn.put_resp_content_type("text/event-stream")
            |> Plug.Conn.send_resp(200, sse_body)
        end
      end)

      assert {:ok, [tool]} =
               Client.list_tools(server, plug: {Req.Test, Liteskill.McpServers.Client})

      assert tool["name"] == "sse_tool"
    end
  end

  describe "headers" do
    test "includes Bearer token when api_key is set" do
      server = build_server(%{api_key: "my-secret-key"})

      stub_with_init(fn conn, _decoded ->
        auth_header =
          conn.req_headers
          |> Enum.find(fn {k, _} -> k == "authorization" end)

        assert auth_header == {"authorization", "Bearer my-secret-key"}

        resp = %{"jsonrpc" => "2.0", "result" => %{"tools" => []}, "id" => 1}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end)

      Client.list_tools(server, plug: {Req.Test, Liteskill.McpServers.Client})
    end

    test "merges custom headers" do
      server = build_server(%{headers: %{"X-Custom" => "custom-val"}})

      stub_with_init(fn conn, _decoded ->
        custom_header =
          conn.req_headers
          |> Enum.find(fn {k, _} -> k == "x-custom" end)

        assert custom_header == {"x-custom", "custom-val"}

        resp = %{"jsonrpc" => "2.0", "result" => %{"tools" => []}, "id" => 1}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end)

      Client.list_tools(server, plug: {Req.Test, Liteskill.McpServers.Client})
    end

    test "skips authorization when api_key is nil" do
      server = build_server(%{api_key: nil})

      stub_with_init(fn conn, _decoded ->
        auth_header =
          conn.req_headers
          |> Enum.find(fn {k, _} -> k == "authorization" end)

        assert auth_header == nil

        resp = %{"jsonrpc" => "2.0", "result" => %{"tools" => []}, "id" => 1}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end)

      Client.list_tools(server, plug: {Req.Test, Liteskill.McpServers.Client})
    end

    test "skips authorization when api_key is empty string" do
      server = build_server(%{api_key: ""})

      stub_with_init(fn conn, _decoded ->
        auth_header =
          conn.req_headers
          |> Enum.find(fn {k, _} -> k == "authorization" end)

        assert auth_header == nil

        resp = %{"jsonrpc" => "2.0", "result" => %{"tools" => []}, "id" => 1}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end)

      Client.list_tools(server, plug: {Req.Test, Liteskill.McpServers.Client})
    end

    test "strips blocked headers from custom headers" do
      server =
        build_server(%{
          headers: %{
            "Authorization" => "evil-override",
            "X-Forwarded-For" => "1.2.3.4",
            "X-Custom-Safe" => "allowed-value",
            "Cookie" => "session=stolen",
            "x-another-safe" => "fine"
          }
        })

      stub_with_init(fn conn, _decoded ->
        header_names = Enum.map(conn.req_headers, fn {k, _} -> k end)

        refute "x-forwarded-for" in header_names
        refute "cookie" in header_names

        custom_safe =
          Enum.find(conn.req_headers, fn {k, _} -> k == "x-custom-safe" end)

        assert custom_safe == {"x-custom-safe", "allowed-value"}

        another_safe =
          Enum.find(conn.req_headers, fn {k, _} -> k == "x-another-safe" end)

        assert another_safe == {"x-another-safe", "fine"}

        resp = %{"jsonrpc" => "2.0", "result" => %{"tools" => []}, "id" => 1}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end)

      assert {:ok, []} =
               Client.list_tools(server, plug: {Req.Test, Liteskill.McpServers.Client})
    end

    test "strips headers with CRLF injection in values" do
      server =
        build_server(%{
          headers: %{
            "X-Safe" => "safe-value",
            "X-Injected" => "value\r\nX-Evil: injected",
            "X-Null" => "val\0ue"
          }
        })

      stub_with_init(fn conn, _decoded ->
        header_names = Enum.map(conn.req_headers, fn {k, _} -> k end)

        assert "x-safe" in header_names
        refute "x-injected" in header_names
        refute "x-null" in header_names

        resp = %{"jsonrpc" => "2.0", "result" => %{"tools" => []}, "id" => 1}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end)

      assert {:ok, []} =
               Client.list_tools(server, plug: {Req.Test, Liteskill.McpServers.Client})
    end

    test "strips headers with CRLF injection in keys" do
      server =
        build_server(%{
          headers: %{
            "X-Good" => "good",
            "X-Bad\r\nEvil" => "value"
          }
        })

      stub_with_init(fn conn, _decoded ->
        header_names = Enum.map(conn.req_headers, fn {k, _} -> k end)

        assert "x-good" in header_names
        refute Enum.any?(header_names, &String.contains?(&1, "evil"))

        resp = %{"jsonrpc" => "2.0", "result" => %{"tools" => []}, "id" => 1}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end)

      assert {:ok, []} =
               Client.list_tools(server, plug: {Req.Test, Liteskill.McpServers.Client})
    end

    test "handles nil headers" do
      server = build_server(%{headers: nil})

      stub_with_init(fn conn, _decoded ->
        resp = %{"jsonrpc" => "2.0", "result" => %{"tools" => []}, "id" => 1}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end)

      assert {:ok, []} =
               Client.list_tools(server, plug: {Req.Test, Liteskill.McpServers.Client})
    end
  end
end
