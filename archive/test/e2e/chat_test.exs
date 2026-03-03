defmodule LiteskillWeb.E2E.ChatTest do
  use LiteskillWeb.FeatureCase, async: false

  alias Liteskill.LlmModels.LlmModel
  alias Liteskill.LlmProviders.LlmProvider
  alias Liteskill.Repo

  test "home page renders chat UI after login", %{session: session} do
    register_user(session)

    session
    |> visit("/")
    |> assert_has(Query.css("h1", text: "What can I help you with?"))
    |> assert_has(Query.css("#message-input"))
    |> take_screenshot(name: "chat/home_page/chat_ui")
  end

  test "message textarea is focusable", %{session: session} do
    register_user(session)

    session
    |> visit("/")
    |> click(Query.css("#message-input"))
    |> fill_in(Query.css("#message-input"), with: "Hello, world!")
    |> take_screenshot(name: "chat/textarea_focusable/filled")

    assert session |> find(Query.css("#message-input")) |> Element.value() == "Hello, world!"
  end

  test "sending a message shows mocked LLM response", %{session: session} do
    mock_llm_stream("Hello! I am a mock assistant.")
    seed_provider_and_model()

    register_user(session)

    session
    |> visit("/")
    |> assert_has(Query.css("#message-input"))
    |> fill_in(Query.css("#message-input"), with: "Hi there!")
    |> click(Query.css("button[type='submit']"))

    # Wait for the mocked stream to complete and the assistant message to appear
    session
    |> assert_has(Query.css(".prose", text: "Hello! I am a mock assistant.", count: :any))
    |> take_screenshot(name: "chat/mocked_llm_response/response")
  end

  @wiki_content """
  # Liteskill

  **Liteskill** is an open-source AI chat platform built with Elixir and Phoenix.

  ## Features

  - Event-sourced conversation history
  - Multi-provider LLM support (AWS Bedrock, Anthropic, OpenAI)
  - Built-in wiki and knowledge base
  - MCP tool integration
  - Real-time streaming responses

  ## Architecture

  Liteskill uses an event-sourced architecture where all conversation state changes
  are stored as immutable events. The system supports branching conversations,
  tool calling, and RAG-powered document retrieval.
  """

  test "tool call: create wiki page about Liteskill", %{session: session} do
    mock_llm_tool_stream(
      [
        # Round 1: assistant decides to create a wiki page
        %{
          text: "I'll create a wiki page about Liteskill for you.",
          tool_calls: [
            %{
              tool_use_id: "toolu_wiki_create",
              name: "wiki__write",
              input: %{
                "actions" => [
                  %{
                    "action" => "create_space",
                    "title" => "Liteskill",
                    "content" => @wiki_content
                  }
                ]
              }
            }
          ]
        },
        # Round 2: summarize what was done
        %{
          text:
            "Done! I've created a wiki page about Liteskill with an overview " <>
              "of its features and architecture. You can find it in the Wiki section."
        }
      ],
      [Liteskill.BuiltinTools.Wiki]
    )

    seed_provider_and_model()
    register_user(session)

    session
    |> visit("/")
    |> assert_has(Query.css("#message-input"))
    |> fill_in(Query.css("#message-input"), with: "Write a wiki page about Liteskill")
    |> click(Query.css("button[type='submit']"))

    # Wait for the tool call to complete and final response to appear
    session
    |> assert_has(Query.css("[phx-click='show_tool_call']", count: :any))
    |> assert_has(Query.css(".prose", text: "I've created a wiki page", count: :any))
    |> take_screenshot(name: "chat/wiki_tool_call/conversation")

    # Let the stream handler finish trailing async projections (chunk casts,
    # complete_stream, usage recording) before the test exits and the sandbox
    # connection is cleaned up.
    Process.sleep(500)

    # Navigate to wiki and find the created space
    session
    |> visit("/wiki")
    |> assert_has(Query.css("h3", text: "Liteskill"))
    |> take_screenshot(name: "chat/wiki_tool_call/space_list")

    # Click the space to see the page content
    session
    |> click(Query.link("Liteskill"))
    |> assert_has(Query.css("#wiki-content"))
    |> assert_has(Query.css("#wiki-content", text: "open-source AI chat platform"))
    |> take_screenshot(name: "chat/wiki_tool_call/page_content")
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
