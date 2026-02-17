defmodule Liteskill.LLM.ToolUtilsTest do
  use ExUnit.Case, async: false

  alias Liteskill.LLM.ToolUtils

  describe "convert_tool/1" do
    test "converts Bedrock tool spec to ReqLLM tool" do
      spec = %{
        "toolSpec" => %{
          "name" => "search",
          "description" => "Search things",
          "inputSchema" => %{"json" => %{"type" => "object"}}
        }
      }

      tool = ToolUtils.convert_tool(spec)
      assert tool.name == "search"
      assert tool.description == "Search things"
    end

    test "handles missing description and schema" do
      spec = %{
        "toolSpec" => %{
          "name" => "minimal"
        }
      }

      tool = ToolUtils.convert_tool(spec)
      assert tool.name == "minimal"
      assert tool.description == ""
    end
  end

  describe "format_tool_output/1" do
    test "formats content list with text entries" do
      result = {:ok, %{"content" => [%{"text" => "hello"}, %{"text" => "world"}]}}
      assert ToolUtils.format_tool_output(result) == "hello\nworld"
    end

    test "formats content list with non-text entries" do
      result = {:ok, %{"content" => [%{"data" => 123}]}}
      output = ToolUtils.format_tool_output(result)
      assert output =~ "data"
    end

    test "formats plain map result" do
      result = {:ok, %{"key" => "value"}}
      assert ToolUtils.format_tool_output(result) == Jason.encode!(%{"key" => "value"})
    end

    test "formats other ok values with inspect" do
      result = {:ok, :some_atom}
      assert ToolUtils.format_tool_output(result) == ":some_atom"
    end

    test "formats error results" do
      result = {:error, "something went wrong"}
      assert ToolUtils.format_tool_output(result) == "Error: tool execution failed"
    end
  end

  describe "execute_tool/4" do
    test "dispatches to builtin module" do
      defmodule FakeBuiltin do
        def call_tool("test_tool", %{"q" => "hello"}, user_id: "u1") do
          {:ok, %{"content" => [%{"text" => "builtin result"}]}}
        end
      end

      server = %{builtin: FakeBuiltin}
      result = ToolUtils.execute_tool(server, "test_tool", %{"q" => "hello"}, user_id: "u1")
      assert {:ok, %{"content" => _}} = result
    end

    test "returns error for nil server" do
      result = ToolUtils.execute_tool(nil, "missing_tool", %{}, [])
      assert {:error, msg} = result
      assert msg =~ "missing_tool"
    end

    test "dispatches to MCP server via McpClient" do
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
            |> Plug.Conn.put_resp_header("mcp-session-id", "test-session")
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(resp))

          "notifications/initialized" ->
            Plug.Conn.send_resp(conn, 200, "")

          _ ->
            assert decoded["method"] == "tools/call"
            assert decoded["params"]["name"] == "mcp_tool"

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              200,
              Jason.encode!(%{
                "jsonrpc" => "2.0",
                "result" => %{"content" => [%{"text" => "mcp result"}]},
                "id" => 1
              })
            )
        end
      end)

      server = %{url: "https://mcp.example.com", api_key: nil, headers: %{}}

      result =
        ToolUtils.execute_tool(server, "mcp_tool", %{"q" => "test"},
          plug: {Req.Test, Liteskill.McpServers.Client}
        )

      assert {:ok, %{"content" => [%{"text" => "mcp result"}]}} = result
    end
  end
end
