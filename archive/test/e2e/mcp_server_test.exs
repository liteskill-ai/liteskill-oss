defmodule LiteskillWeb.E2E.McpServerTest do
  use LiteskillWeb.FeatureCase, async: false

  alias Liteskill.LlmModels.LlmModel
  alias Liteskill.LlmProviders.LlmProvider
  alias Liteskill.McpServers.McpServer
  alias Liteskill.Repo

  @tool_specs [
    %{
      "name" => "get_weather",
      "description" => "Get the current weather for a city",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "city" => %{"type" => "string", "description" => "The city name"}
        },
        "required" => ["city"]
      }
    }
  ]

  @tool_results %{
    "get_weather" => %{
      "content" => [%{"type" => "text", "text" => "Sunny, 72°F in San Francisco"}]
    }
  }

  test "register server and view tools", %{session: session} do
    stub_mcp_client(@tool_specs, @tool_results)
    register_user(session)

    # Verify we're authenticated before navigating
    assert_has(session, Query.css("#message-input"))

    # Navigate to Tools page
    session
    |> visit("/mcp")
    |> assert_has(Query.css("h1", text: "Tools"))

    # Click Add Server and fill the form
    session
    |> click(Query.button("Add Server"))
    |> assert_has(Query.css("#mcp-modal"))
    |> fill_in(Query.css("input[name='mcp_server[name]']"), with: "Weather API")
    |> fill_in(Query.css("input[name='mcp_server[url]']"), with: "https://weather-api.example.com/mcp")
    |> fill_in(Query.css("textarea[name='mcp_server[description]']"), with: "Provides real-time weather data")
    |> take_screenshot(name: "mcp_server/register_and_view_tools/form_filled")

    # Submit the form
    session
    |> click(Query.button("Create"))
    |> assert_has(Query.css("h3", text: "Weather API"))
    |> take_screenshot(name: "mcp_server/register_and_view_tools/server_registered")

    # Open the Actions dropdown on the Weather API card and click Tools
    card = find(session, Query.css(".card", text: "Weather API"))
    card |> find(Query.css("[role='button']", text: "Actions")) |> Element.click()
    card |> find(Query.css("button", text: "Tools")) |> Element.click()

    # Wait for tools modal to load and show the tool
    session
    |> assert_has(Query.css("#tools-modal"))
    |> assert_has(Query.css(".font-mono", text: "get_weather"))
    |> take_screenshot(name: "mcp_server/register_and_view_tools/tools_modal")
  end

  test "use MCP tool in conversation", %{session: session} do
    stub_mcp_client(@tool_specs, @tool_results)
    server = seed_mcp_server()

    mock_mcp_tool_stream(
      [
        # Round 1: LLM decides to call get_weather
        %{
          text: "Let me check the weather in San Francisco for you.",
          tool_calls: [
            %{
              tool_use_id: "toolu_weather_1",
              name: "get_weather",
              input: %{"city" => "San Francisco"}
            }
          ]
        },
        # Round 2: LLM summarizes the tool result
        %{
          text: "The weather in San Francisco is sunny and 72°F. Perfect day to be outside!"
        }
      ],
      server,
      @tool_specs
    )

    seed_provider_and_model()
    register_user(session)

    session
    |> visit("/")
    |> assert_has(Query.css("#message-input"))
    |> fill_in(Query.css("#message-input"), with: "What's the weather in San Francisco?")
    |> click(Query.css("button[type='submit']"))

    # Wait for tool call to complete and final response to appear
    session
    |> assert_has(Query.css("[phx-click='show_tool_call']", count: :any))
    |> assert_has(Query.css(".prose", text: "sunny and 72°F", count: :any))
    # Wait for streaming to finish (textarea re-enabled)
    |> assert_has(Query.css("#message-input:not([disabled])"))
    |> take_screenshot(name: "mcp_server/use_in_conversation/tool_call_response")
  end

  defp seed_mcp_server do
    %{id: user_id} = create_user(%{email: "seed-mcp@example.com"}).user

    Repo.insert!(%McpServer{
      name: "Weather API",
      url: "https://weather-api.example.com/mcp",
      description: "Provides real-time weather data",
      status: "active",
      global: true,
      user_id: user_id
    })
  end

  defp seed_provider_and_model do
    %{id: user_id} = create_user(%{email: "seed-llm@example.com"}).user

    provider =
      Repo.insert!(%LlmProvider{
        name: "E2E Test Provider",
        provider_type: "anthropic",
        api_key: "sk-fake",
        instance_wide: true,
        status: "active",
        user_id: user_id
      })

    Repo.insert!(%LlmModel{
      name: "E2E Test Model",
      model_id: "claude-test",
      model_type: "inference",
      instance_wide: true,
      status: "active",
      provider_id: provider.id,
      user_id: user_id
    })
  end
end
