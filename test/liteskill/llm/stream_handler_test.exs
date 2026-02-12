defmodule Liteskill.LLM.StreamHandlerTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Chat
  alias Liteskill.EventStore.Postgres, as: Store
  alias Liteskill.LLM.StreamHandler

  setup do
    Application.put_env(:liteskill, Liteskill.LLM,
      bedrock_region: "us-east-1",
      bedrock_model_id: "us.anthropic.claude-3-5-sonnet-20241022-v2:0",
      bedrock_bearer_token: "test-token"
    )

    {:ok, user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "stream-test-#{System.unique_integer([:positive])}@example.com",
        name: "Stream Test",
        oidc_sub: "stream-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Stream Test"})
    {:ok, _msg} = Chat.send_message(conv.id, user.id, "Hello!")

    on_exit(fn -> :ok end)

    %{user: user, conversation: conv}
  end

  test "successful stream with completion", %{conversation: conv} do
    Req.Test.stub(Liteskill.LLM.BedrockClient, fn conn ->
      conn
      |> Plug.Conn.send_resp(200, "")
    end)

    stream_id = conv.stream_id
    messages = [%{role: :user, content: "test"}]

    assert :ok =
             StreamHandler.handle_stream(stream_id, messages,
               plug: {Req.Test, Liteskill.LLM.BedrockClient}
             )

    events = Store.read_stream_forward(stream_id)
    event_types = Enum.map(events, & &1.event_type)
    assert "AssistantStreamStarted" in event_types
    assert "AssistantStreamCompleted" in event_types
  end

  test "stream request error records AssistantStreamFailed", %{conversation: conv} do
    stream_id = conv.stream_id
    messages = [%{role: :user, content: "test"}]

    # Without a Req.Test stub or valid config, the HTTP call will fail
    _result = StreamHandler.handle_stream(stream_id, messages)

    events = Store.read_stream_forward(stream_id)
    event_types = Enum.map(events, & &1.event_type)
    assert "AssistantStreamStarted" in event_types
    assert "AssistantStreamFailed" in event_types
  end

  test "handle_stream fails when conversation is archived", %{user: user} do
    {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Archive Test"})
    {:ok, _} = Chat.archive_conversation(conv.id, user.id)

    assert {:error, :conversation_archived} =
             StreamHandler.handle_stream(conv.stream_id, [%{role: :user, content: "test"}])
  end

  test "passes model_id option", %{conversation: conv} do
    Req.Test.stub(Liteskill.LLM.BedrockClient, fn conn ->
      conn |> Plug.Conn.send_resp(200, "")
    end)

    stream_id = conv.stream_id

    StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
      model_id: "custom-model",
      plug: {Req.Test, Liteskill.LLM.BedrockClient}
    )

    events = Store.read_stream_forward(stream_id)

    started_events =
      Enum.filter(events, &(&1.event_type == "AssistantStreamStarted"))

    last_started = List.last(started_events)
    assert last_started.data["model_id"] == "custom-model"
  end

  test "passes system prompt option", %{conversation: conv} do
    Req.Test.stub(Liteskill.LLM.BedrockClient, fn conn ->
      conn |> Plug.Conn.send_resp(200, "")
    end)

    stream_id = conv.stream_id

    assert :ok =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               system: "Be brief",
               plug: {Req.Test, Liteskill.LLM.BedrockClient}
             )
  end

  test "stream completion records full_content and stop_reason", %{conversation: conv} do
    Req.Test.stub(Liteskill.LLM.BedrockClient, fn conn ->
      conn |> Plug.Conn.send_resp(200, "")
    end)

    stream_id = conv.stream_id

    assert :ok =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               plug: {Req.Test, Liteskill.LLM.BedrockClient}
             )

    events = Store.read_stream_forward(stream_id)
    completed = Enum.find(events, &(&1.event_type == "AssistantStreamCompleted"))
    assert completed != nil
    assert completed.data["full_content"] == ""
    assert completed.data["stop_reason"] == "end_turn"
  end

  test "retries on 503 with backoff then succeeds", %{conversation: conv} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(Liteskill.LLM.BedrockClient, fn conn ->
      count = Agent.get_and_update(counter, &{&1, &1 + 1})

      if count < 1 do
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(503, Jason.encode!(%{"message" => "unavailable"}))
      else
        conn |> Plug.Conn.send_resp(200, "")
      end
    end)

    stream_id = conv.stream_id

    assert :ok =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               plug: {Req.Test, Liteskill.LLM.BedrockClient},
               backoff_ms: 1
             )

    Agent.stop(counter)

    events = Store.read_stream_forward(stream_id)
    event_types = Enum.map(events, & &1.event_type)
    assert "AssistantStreamCompleted" in event_types
  end

  test "fails after max retries exceeded", %{conversation: conv} do
    # Always return 503 to exhaust retries
    Req.Test.stub(Liteskill.LLM.BedrockClient, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(429, Jason.encode!(%{"message" => "rate limited"}))
    end)

    stream_id = conv.stream_id

    assert {:error, {"max_retries_exceeded", _}} =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               plug: {Req.Test, Liteskill.LLM.BedrockClient},
               backoff_ms: 1
             )

    events = Store.read_stream_forward(stream_id)
    event_types = Enum.map(events, & &1.event_type)
    assert "AssistantStreamFailed" in event_types

    failed = Enum.find(events, &(&1.event_type == "AssistantStreamFailed"))
    assert failed.data["error_type"] == "max_retries_exceeded"
  end

  test "stream with tools option passes toolConfig in request body", %{conversation: conv} do
    Req.Test.stub(Liteskill.LLM.BedrockClient, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)

      # Verify toolConfig is present
      assert decoded["toolConfig"] != nil
      assert decoded["toolConfig"]["tools"] != nil
      assert length(decoded["toolConfig"]["tools"]) == 1

      tool = hd(decoded["toolConfig"]["tools"])
      assert tool["toolSpec"]["name"] == "get_weather"

      conn |> Plug.Conn.send_resp(200, "")
    end)

    tools = [
      %{
        "toolSpec" => %{
          "name" => "get_weather",
          "description" => "Get weather",
          "inputSchema" => %{"json" => %{"type" => "object"}}
        }
      }
    ]

    stream_id = conv.stream_id

    assert :ok =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               plug: {Req.Test, Liteskill.LLM.BedrockClient},
               tools: tools
             )

    events = Store.read_stream_forward(stream_id)
    event_types = Enum.map(events, & &1.event_type)
    assert "AssistantStreamCompleted" in event_types
  end

  test "returns error when max tool rounds exceeded", %{conversation: conv} do
    stream_id = conv.stream_id

    # Simulate being at the max tool round limit
    assert {:error, :max_tool_rounds_exceeded} =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               tool_round: 10,
               max_tool_rounds: 10
             )
  end

  test "allows stream when under max tool rounds", %{conversation: conv} do
    Req.Test.stub(Liteskill.LLM.BedrockClient, fn conn ->
      conn |> Plug.Conn.send_resp(200, "")
    end)

    stream_id = conv.stream_id

    assert :ok =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               tool_round: 5,
               max_tool_rounds: 10,
               plug: {Req.Test, Liteskill.LLM.BedrockClient}
             )
  end

  test "stream without tools does not include toolConfig", %{conversation: conv} do
    Req.Test.stub(Liteskill.LLM.BedrockClient, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)

      # No toolConfig when no tools
      assert decoded["toolConfig"] == nil

      conn |> Plug.Conn.send_resp(200, "")
    end)

    stream_id = conv.stream_id

    assert :ok =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               plug: {Req.Test, Liteskill.LLM.BedrockClient}
             )
  end

  describe "parse_tool_calls/1" do
    test "parses valid JSON input parts" do
      tool_calls = [
        %{
          tool_use_id: "id1",
          name: "get_weather",
          input_parts: ["ation\":\"NYC\"}", "{\"loc"]
        }
      ]

      result = StreamHandler.parse_tool_calls(tool_calls)
      assert [%{tool_use_id: "id1", name: "get_weather", input: %{"location" => "NYC"}}] = result
    end

    test "returns empty map for invalid JSON" do
      tool_calls = [
        %{tool_use_id: "id1", name: "broken", input_parts: ["not json"]}
      ]

      result = StreamHandler.parse_tool_calls(tool_calls)
      assert [%{input: %{}}] = result
    end

    test "handles empty input parts" do
      tool_calls = [
        %{tool_use_id: "id1", name: "noop", input_parts: []}
      ]

      result = StreamHandler.parse_tool_calls(tool_calls)
      assert [%{input: %{}}] = result
    end
  end

  describe "validate_tool_calls/2" do
    test "filters to only allowed tool names" do
      tool_calls = [
        %{tool_use_id: "1", name: "allowed_tool", input: %{}},
        %{tool_use_id: "2", name: "forbidden_tool", input: %{}}
      ]

      tools = [
        %{"toolSpec" => %{"name" => "allowed_tool", "description" => "ok"}}
      ]

      result = StreamHandler.validate_tool_calls(tool_calls, tools)
      assert length(result) == 1
      assert hd(result).name == "allowed_tool"
    end

    test "returns no tool calls when tools list is empty (deny-all)" do
      tool_calls = [
        %{tool_use_id: "1", name: "any_tool", input: %{}}
      ]

      result = StreamHandler.validate_tool_calls(tool_calls, [])
      assert result == []
    end
  end

  describe "build_assistant_content/2" do
    test "builds text + toolUse blocks" do
      tool_calls = [
        %{tool_use_id: "id1", name: "search", input: %{"q" => "test"}}
      ]

      result = StreamHandler.build_assistant_content("Hello", tool_calls)

      assert [
               %{"text" => "Hello"},
               %{
                 "toolUse" => %{
                   "toolUseId" => "id1",
                   "name" => "search",
                   "input" => %{"q" => "test"}
                 }
               }
             ] = result
    end

    test "omits text block when content is empty" do
      tool_calls = [%{tool_use_id: "id1", name: "tool", input: %{}}]
      result = StreamHandler.build_assistant_content("", tool_calls)
      assert [%{"toolUse" => _}] = result
    end

    test "returns only text block when no tool calls" do
      result = StreamHandler.build_assistant_content("Just text", [])
      assert [%{"text" => "Just text"}] = result
    end
  end

  describe "tool-calling path via FakeProvider" do
    setup %{conversation: conv} do
      on_exit(fn ->
        Process.delete(:fake_provider_events)
        Process.delete(:fake_provider_round)
        Process.delete(:fake_provider_events_round_0)
        Process.delete(:fake_provider_events_round_1)
        Process.delete(:fake_tool_results)
      end)

      %{stream_id: conv.stream_id}
    end

    defp tool_call_events(tool_use_id, tool_name, input_json) do
      [
        {:content_block_delta,
         %{"delta" => %{"text" => "Let me check that."}, "contentBlockIndex" => 0}},
        {:content_block_start,
         %{
           "start" => %{
             "toolUse" => %{"toolUseId" => tool_use_id, "name" => tool_name}
           }
         }},
        {:content_block_delta, %{"delta" => %{"toolUse" => %{"input" => input_json}}}}
      ]
    end

    defp text_only_events(text) do
      [{:content_block_delta, %{"delta" => %{"text" => text}, "contentBlockIndex" => 0}}]
    end

    test "auto_confirm executes tool and continues to next round", %{stream_id: stream_id} do
      tool_use_id = "toolu_#{System.unique_integer([:positive])}"

      # Round 0: LLM returns a tool call
      Process.put(
        :fake_provider_events_round_0,
        tool_call_events(tool_use_id, "get_weather", "{\"city\":\"NYC\"}")
      )

      # Round 1: LLM returns text only (no more tool calls)
      Process.put(:fake_provider_events_round_1, text_only_events("The weather is sunny."))

      tools = [
        %{"toolSpec" => %{"name" => "get_weather", "description" => "Get weather"}}
      ]

      assert :ok =
               StreamHandler.handle_stream(
                 stream_id,
                 [%{role: :user, content: "What's the weather?"}],
                 provider: Liteskill.LLM.FakeProvider,
                 tools: tools,
                 tool_servers: %{"get_weather" => %{builtin: Liteskill.LLM.FakeToolServer}},
                 auto_confirm: true
               )

      events = Store.read_stream_forward(stream_id)
      event_types = Enum.map(events, & &1.event_type)

      # Should have: started, chunks, tool_call_started, tool_call_completed,
      # completed (tool_use), started (round 2), chunks, completed (end_turn)
      assert "ToolCallStarted" in event_types
      assert "ToolCallCompleted" in event_types
      assert Enum.count(event_types, &(&1 == "AssistantStreamStarted")) == 2
      assert Enum.count(event_types, &(&1 == "AssistantStreamCompleted")) == 2

      # First completion should have stop_reason="tool_use"
      completions = Enum.filter(events, &(&1.event_type == "AssistantStreamCompleted"))
      assert hd(completions).data["stop_reason"] == "tool_use"
      assert List.last(completions).data["stop_reason"] == "end_turn"
    end

    test "auto_confirm records tool call with correct input and output", %{stream_id: stream_id} do
      tool_use_id = "toolu_#{System.unique_integer([:positive])}"

      Process.put(
        :fake_provider_events_round_0,
        tool_call_events(tool_use_id, "search", "{\"q\":\"elixir\"}")
      )

      Process.put(:fake_provider_events_round_1, text_only_events("Found results."))

      Process.put(:fake_tool_results, %{
        "search" => {:ok, %{"content" => [%{"text" => "Elixir is great"}]}}
      })

      tools = [%{"toolSpec" => %{"name" => "search", "description" => "Search"}}]

      assert :ok =
               StreamHandler.handle_stream(stream_id, [%{role: :user, content: "search"}],
                 provider: Liteskill.LLM.FakeProvider,
                 tools: tools,
                 tool_servers: %{"search" => %{builtin: Liteskill.LLM.FakeToolServer}},
                 auto_confirm: true
               )

      events = Store.read_stream_forward(stream_id)

      tc_started = Enum.find(events, &(&1.event_type == "ToolCallStarted"))
      assert tc_started.data["tool_name"] == "search"
      assert tc_started.data["input"] == %{"q" => "elixir"}

      tc_completed = Enum.find(events, &(&1.event_type == "ToolCallCompleted"))
      assert tc_completed.data["tool_name"] == "search"
      assert tc_completed.data["output"] == %{"content" => [%{"text" => "Elixir is great"}]}
    end

    test "filters out tool calls not in allowed tools list", %{stream_id: stream_id} do
      tool_use_id = "toolu_#{System.unique_integer([:positive])}"

      # LLM tries to call "forbidden_tool" which isn't in our tools list
      Process.put(:fake_provider_events, [
        {:content_block_start,
         %{"start" => %{"toolUse" => %{"toolUseId" => tool_use_id, "name" => "forbidden_tool"}}}},
        {:content_block_delta, %{"delta" => %{"toolUse" => %{"input" => "{}"}}}}
      ])

      # Only "allowed_tool" is in the tools list
      tools = [%{"toolSpec" => %{"name" => "allowed_tool", "description" => "ok"}}]

      assert :ok =
               StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
                 provider: Liteskill.LLM.FakeProvider,
                 tools: tools,
                 auto_confirm: true
               )

      events = Store.read_stream_forward(stream_id)
      event_types = Enum.map(events, & &1.event_type)

      # No tool call events since the tool was filtered out
      refute "ToolCallStarted" in event_types
      # Stream completes with end_turn (no valid tool calls to process)
      assert "AssistantStreamCompleted" in event_types
    end

    test "handles tool execution error", %{stream_id: stream_id} do
      tool_use_id = "toolu_#{System.unique_integer([:positive])}"

      Process.put(
        :fake_provider_events_round_0,
        tool_call_events(tool_use_id, "failing_tool", "{}")
      )

      Process.put(:fake_provider_events_round_1, text_only_events("Tool failed."))
      Process.put(:fake_tool_results, %{"failing_tool" => {:error, "connection timeout"}})

      tools = [%{"toolSpec" => %{"name" => "failing_tool", "description" => "Fails"}}]

      assert :ok =
               StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
                 provider: Liteskill.LLM.FakeProvider,
                 tools: tools,
                 tool_servers: %{"failing_tool" => %{builtin: Liteskill.LLM.FakeToolServer}},
                 auto_confirm: true
               )

      events = Store.read_stream_forward(stream_id)

      tc_completed = Enum.find(events, &(&1.event_type == "ToolCallCompleted"))
      assert tc_completed.data["output"]["error"] =~ "connection timeout"
    end

    test "tool server nil returns error for unconfigured tool", %{stream_id: stream_id} do
      tool_use_id = "toolu_#{System.unique_integer([:positive])}"

      Process.put(
        :fake_provider_events_round_0,
        tool_call_events(tool_use_id, "no_server_tool", "{}")
      )

      Process.put(:fake_provider_events_round_1, text_only_events("Done."))

      tools = [%{"toolSpec" => %{"name" => "no_server_tool", "description" => "No server"}}]

      # No tool_servers configured — server will be nil
      assert :ok =
               StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
                 provider: Liteskill.LLM.FakeProvider,
                 tools: tools,
                 auto_confirm: true
               )

      events = Store.read_stream_forward(stream_id)
      tc_completed = Enum.find(events, &(&1.event_type == "ToolCallCompleted"))
      assert tc_completed.data["output"]["error"] =~ "No server configured"
    end

    test "manual confirm rejects tool calls on timeout", %{stream_id: stream_id} do
      tool_use_id = "toolu_#{System.unique_integer([:positive])}"

      Process.put(:fake_provider_events_round_0, tool_call_events(tool_use_id, "slow_tool", "{}"))
      Process.put(:fake_provider_events_round_1, text_only_events("Rejected."))

      tools = [%{"toolSpec" => %{"name" => "slow_tool", "description" => "Slow"}}]

      assert :ok =
               StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
                 provider: Liteskill.LLM.FakeProvider,
                 tools: tools,
                 auto_confirm: false,
                 tool_approval_timeout_ms: 1
               )

      events = Store.read_stream_forward(stream_id)

      tc_completed = Enum.find(events, &(&1.event_type == "ToolCallCompleted"))
      assert tc_completed.data["output"]["error"] =~ "rejected by user"
    end

    test "manual confirm approves tool call via PubSub", %{stream_id: stream_id} do
      tool_use_id = "toolu_#{System.unique_integer([:positive])}"

      Process.put(
        :fake_provider_events_round_0,
        tool_call_events(tool_use_id, "approved_tool", "{}")
      )

      Process.put(:fake_provider_events_round_1, text_only_events("Approved and done."))

      tools = [%{"toolSpec" => %{"name" => "approved_tool", "description" => "Will be approved"}}]

      # Send approval after a short delay
      approval_topic = "tool_approval:#{stream_id}"
      test_pid = self()

      spawn(fn ->
        # Wait for the subscription to be established
        Process.sleep(50)

        Phoenix.PubSub.broadcast(
          Liteskill.PubSub,
          approval_topic,
          {:tool_decision, tool_use_id, :approved}
        )

        send(test_pid, :approval_sent)
      end)

      assert :ok =
               StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
                 provider: Liteskill.LLM.FakeProvider,
                 tools: tools,
                 tool_servers: %{"approved_tool" => %{builtin: Liteskill.LLM.FakeToolServer}},
                 auto_confirm: false,
                 tool_approval_timeout_ms: 5000
               )

      assert_receive :approval_sent, 5000

      events = Store.read_stream_forward(stream_id)
      event_types = Enum.map(events, & &1.event_type)

      assert "ToolCallStarted" in event_types
      assert "ToolCallCompleted" in event_types

      tc_completed = Enum.find(events, &(&1.event_type == "ToolCallCompleted"))
      # Should have actual tool output, not rejection
      refute tc_completed.data["output"]["error"]
    end

    test "records text chunks via content_block_delta", %{stream_id: stream_id} do
      Process.put(:fake_provider_events, [
        {:content_block_delta, %{"delta" => %{"text" => "Hello "}, "contentBlockIndex" => 0}},
        {:content_block_delta, %{"delta" => %{"text" => "world!"}, "contentBlockIndex" => 0}}
      ])

      assert :ok =
               StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
                 provider: Liteskill.LLM.FakeProvider
               )

      events = Store.read_stream_forward(stream_id)

      chunks = Enum.filter(events, &(&1.event_type == "AssistantChunkReceived"))
      assert length(chunks) == 2
      assert hd(chunks).data["delta_text"] == "Hello "

      completed = Enum.find(events, &(&1.event_type == "AssistantStreamCompleted"))
      assert completed.data["full_content"] == "Hello world!"
    end
  end

  describe "format_tool_output/1" do
    test "formats MCP content list" do
      result =
        StreamHandler.format_tool_output(
          {:ok, %{"content" => [%{"text" => "line1"}, %{"text" => "line2"}]}}
        )

      assert result == "line1\nline2"
    end

    test "formats non-text content items as JSON" do
      result =
        StreamHandler.format_tool_output({:ok, %{"content" => [%{"image" => "data"}]}})

      assert result == "{\"image\":\"data\"}"
    end

    test "formats plain map as JSON" do
      result = StreamHandler.format_tool_output({:ok, %{"key" => "value"}})
      assert result == "{\"key\":\"value\"}"
    end

    test "formats non-map data with inspect" do
      result = StreamHandler.format_tool_output({:ok, 42})
      assert result == "42"
    end

    test "formats error tuple" do
      result = StreamHandler.format_tool_output({:error, "timeout"})
      assert result == "Error: \"timeout\""
    end
  end
end
