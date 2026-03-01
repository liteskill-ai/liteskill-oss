defmodule Liteskill.LLM.StreamHandlerTest do
  use Liteskill.DataCase, async: false

  import Liteskill.RetryTestHelpers

  alias Liteskill.Chat
  alias Liteskill.EventStore.Postgres, as: Store
  alias Liteskill.LLM.FakeToolServer
  alias Liteskill.LLM.StreamHandler
  alias Liteskill.LlmGateway.ProviderGate
  alias Liteskill.LlmModels.LlmModel
  alias Liteskill.LlmProviders.LlmProvider
  alias Liteskill.Usage.UsageRecord
  alias ReqLLM.Error.API.Request

  setup do
    Application.put_env(:liteskill, Liteskill.LLM,
      bedrock_region: "us-east-1",
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

  # -- Helper: build a stream_fn that returns text --

  defp text_stream_fn(text) do
    fn _model_id, _messages, on_chunk, _opts ->
      Enum.each(String.graphemes(text), fn char -> on_chunk.(char) end)
      {:ok, text, []}
    end
  end

  defp text_chunks_stream_fn(chunks) do
    fn _model_id, _messages, on_chunk, _opts ->
      Enum.each(chunks, fn chunk -> on_chunk.(chunk) end)
      full = Enum.join(chunks, "")
      {:ok, full, []}
    end
  end

  defp tool_call_stream_fn(text, tool_calls, opts \\ []) do
    round_1_fn = Keyword.get(opts, :round_1_fn)

    fn model_id, messages, on_chunk, call_opts ->
      round = Process.get(:stream_fn_round, 0)
      Process.put(:stream_fn_round, round + 1)

      if round == 0 do
        if text != "", do: on_chunk.(text)
        {:ok, text, tool_calls}
      else
        r1 =
          round_1_fn ||
            fn _m, _ms, cb, _o ->
              cb.("Done.")
              {:ok, "Done.", []}
            end

        r1.(model_id, messages, on_chunk, call_opts)
      end
    end
  end

  defp text_stream_fn_with_usage(text, usage) do
    fn _model_id, _messages, on_chunk, _opts ->
      Enum.each(String.graphemes(text), fn char -> on_chunk.(char) end)
      {:ok, text, [], usage}
    end
  end

  defp error_stream_fn(error) do
    fn _model_id, _messages, _on_chunk, _opts ->
      {:error, error}
    end
  end

  test "successful stream with completion", %{conversation: conv} do
    stream_id = conv.stream_id

    assert :ok =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               model_id: "test-model",
               stream_fn: text_stream_fn("Hello!")
             )

    events = Store.read_stream_forward(stream_id)
    event_types = Enum.map(events, & &1.event_type)
    assert "AssistantStreamStarted" in event_types
    assert "AssistantStreamCompleted" in event_types
  end

  test "stream request error records AssistantStreamFailed with actual error message", %{
    conversation: conv
  } do
    stream_id = conv.stream_id

    assert {:error, {"request_error", msg}} =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               model_id: "test-model",
               stream_fn: error_stream_fn(%{status: 403, body: "Access denied"})
             )

    assert msg == "HTTP 403: Access denied"

    events = Store.read_stream_forward(stream_id)
    event_types = Enum.map(events, & &1.event_type)
    assert "AssistantStreamStarted" in event_types
    assert "AssistantStreamFailed" in event_types

    failed = Enum.find(events, &(&1.event_type == "AssistantStreamFailed"))
    assert failed.data["error_message"] == "HTTP 403: Access denied"
  end

  test "handle_stream fails when conversation is archived", %{user: user} do
    {:ok, conv} = Chat.create_conversation(%{user_id: user.id, title: "Archive Test"})
    {:ok, _} = Chat.archive_conversation(conv.id, user.id)

    assert {:error, :conversation_archived} =
             StreamHandler.handle_stream(conv.stream_id, [%{role: :user, content: "test"}], model_id: "test-model")
  end

  test "raises when no model specified", %{conversation: conv} do
    assert_raise RuntimeError, ~r/No model specified/, fn ->
      StreamHandler.handle_stream(conv.stream_id, [%{role: :user, content: "test"}], stream_fn: text_stream_fn(""))
    end
  end

  test "uses llm_model for model_id and provider options", %{conversation: conv} do
    llm_model = %LlmModel{
      model_id: "claude-custom",
      provider: %LlmProvider{
        provider_type: "anthropic",
        api_key: "test-key",
        provider_config: %{}
      }
    }

    stream_id = conv.stream_id

    assert :ok =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               llm_model: llm_model,
               stream_fn: fn _model_id, _msgs, _cb, opts ->
                 assert Keyword.get(opts, :api_key) == "test-key"
                 # model_spec is a plain map, not the full LlmModel struct
                 model_spec = Keyword.get(opts, :model_spec)
                 assert model_spec == %{id: "claude-custom", provider: :anthropic}
                 refute Keyword.has_key?(opts, :llm_model)
                 {:ok, "", []}
               end
             )

    events = Store.read_stream_forward(stream_id)
    started_events = Enum.filter(events, &(&1.event_type == "AssistantStreamStarted"))
    last_started = List.last(started_events)
    assert last_started.data["model_id"] == "claude-custom"
  end

  test "passes model_id option", %{conversation: conv} do
    stream_id = conv.stream_id

    StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
      model_id: "custom-model",
      stream_fn: text_stream_fn("")
    )

    events = Store.read_stream_forward(stream_id)
    started_events = Enum.filter(events, &(&1.event_type == "AssistantStreamStarted"))
    last_started = List.last(started_events)
    assert last_started.data["model_id"] == "custom-model"
  end

  test "passes system prompt option via call_opts", %{conversation: conv} do
    stream_id = conv.stream_id

    assert :ok =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               model_id: "test-model",
               system: "Be brief",
               stream_fn: fn _model, _msgs, _cb, opts ->
                 assert Keyword.get(opts, :system_prompt) == "Be brief"
                 {:ok, "", []}
               end
             )
  end

  test "passes temperature and max_tokens via call_opts", %{conversation: conv} do
    stream_id = conv.stream_id

    assert :ok =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               model_id: "test-model",
               temperature: 0.7,
               max_tokens: 2048,
               stream_fn: fn _model, _msgs, _cb, opts ->
                 assert Keyword.get(opts, :temperature) == 0.7
                 assert Keyword.get(opts, :max_tokens) == 2048
                 {:ok, "", []}
               end
             )
  end

  test "empty tools list does not include tools in call_opts", %{conversation: conv} do
    stream_id = conv.stream_id

    assert :ok =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               model_id: "test-model",
               tools: [],
               stream_fn: fn _model, _msgs, _cb, opts ->
                 assert Keyword.get(opts, :tools) == nil
                 {:ok, "", []}
               end
             )
  end

  test "stream completion records full_content and stop_reason", %{conversation: conv} do
    stream_id = conv.stream_id

    assert :ok =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               model_id: "test-model",
               stream_fn: text_stream_fn("response text")
             )

    events = Store.read_stream_forward(stream_id)
    completed = Enum.find(events, &(&1.event_type == "AssistantStreamCompleted"))
    assert completed
    assert completed.data["full_content"] == "response text"
    assert completed.data["stop_reason"] == "end_turn"
  end

  test "retries on 503 with backoff then succeeds", %{conversation: conv} do
    counter = retry_counter()

    retry_fn = fn _model, _msgs, on_chunk, _opts ->
      count = next_count(counter)

      if count < 1 do
        {:error, %{status: 503, body: "unavailable"}}
      else
        on_chunk.("ok")
        {:ok, "ok", []}
      end
    end

    stream_id = conv.stream_id

    assert :ok =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               model_id: "test-model",
               stream_fn: retry_fn,
               backoff_ms: 1
             )

    Agent.stop(counter)

    events = Store.read_stream_forward(stream_id)
    event_types = Enum.map(events, & &1.event_type)
    assert "AssistantStreamCompleted" in event_types
  end

  test "fails after max retries exceeded", %{conversation: conv} do
    stream_id = conv.stream_id

    assert {:error, {"max_retries_exceeded", _}} =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               model_id: "test-model",
               stream_fn: error_stream_fn(%{status: 429, body: "rate limited"}),
               backoff_ms: 1
             )

    events = Store.read_stream_forward(stream_id)
    event_types = Enum.map(events, & &1.event_type)
    assert "AssistantStreamFailed" in event_types

    failed = Enum.find(events, &(&1.event_type == "AssistantStreamFailed"))
    assert failed.data["error_type"] == "max_retries_exceeded"
  end

  test "retries on transport error then succeeds", %{conversation: conv} do
    counter = retry_counter()

    retry_fn = fn _model, _msgs, on_chunk, _opts ->
      count = next_count(counter)

      if count < 1 do
        {:error, %Mint.TransportError{reason: :timeout}}
      else
        on_chunk.("ok")
        {:ok, "ok", []}
      end
    end

    stream_id = conv.stream_id

    assert :ok =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               model_id: "test-model",
               stream_fn: retry_fn,
               backoff_ms: 1
             )

    Agent.stop(counter)

    events = Store.read_stream_forward(stream_id)
    event_types = Enum.map(events, & &1.event_type)
    assert "AssistantStreamCompleted" in event_types
  end

  test "retries on HTTP 408 timeout then succeeds", %{conversation: conv} do
    counter = retry_counter()

    retry_fn = fn _model, _msgs, on_chunk, _opts ->
      count = next_count(counter)

      if count < 1 do
        {:error, %{status: 408, body: "Request Timeout"}}
      else
        on_chunk.("ok")
        {:ok, "ok", []}
      end
    end

    stream_id = conv.stream_id

    assert :ok =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               model_id: "test-model",
               stream_fn: retry_fn,
               backoff_ms: 1
             )

    Agent.stop(counter)

    events = Store.read_stream_forward(stream_id)
    event_types = Enum.map(events, & &1.event_type)
    assert "AssistantStreamCompleted" in event_types
  end

  test "retries on :timeout atom error then succeeds", %{conversation: conv} do
    counter = retry_counter()

    retry_fn = fn _model, _msgs, on_chunk, _opts ->
      count = next_count(counter)

      if count < 1 do
        {:error, :timeout}
      else
        on_chunk.("ok")
        {:ok, "ok", []}
      end
    end

    stream_id = conv.stream_id

    assert :ok =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               model_id: "test-model",
               stream_fn: retry_fn,
               backoff_ms: 1
             )

    Agent.stop(counter)

    events = Store.read_stream_forward(stream_id)
    event_types = Enum.map(events, & &1.event_type)
    assert "AssistantStreamCompleted" in event_types
  end

  test "max retries exceeded on transport error", %{conversation: conv} do
    stream_id = conv.stream_id

    assert {:error, {"max_retries_exceeded", _}} =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               model_id: "test-model",
               stream_fn: error_stream_fn(%Mint.TransportError{reason: :closed}),
               backoff_ms: 1
             )

    events = Store.read_stream_forward(stream_id)
    failed = Enum.find(events, &(&1.event_type == "AssistantStreamFailed"))
    assert failed.data["error_type"] == "max_retries_exceeded"
  end

  test "retries on ReqLLM timeout error (reason: timeout, status: nil) then succeeds", %{
    conversation: conv
  } do
    counter = retry_counter()

    retry_fn = fn _model, _msgs, on_chunk, _opts ->
      count = next_count(counter)

      if count < 1 do
        {:error, %Request{reason: "timeout", status: nil}}
      else
        on_chunk.("ok")
        {:ok, "ok", []}
      end
    end

    stream_id = conv.stream_id

    assert :ok =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               model_id: "test-model",
               stream_fn: retry_fn,
               backoff_ms: 1
             )

    Agent.stop(counter)

    events = Store.read_stream_forward(stream_id)
    event_types = Enum.map(events, & &1.event_type)
    assert "AssistantStreamCompleted" in event_types
  end

  test "retries on GenServer call timeout tuple then succeeds", %{conversation: conv} do
    counter = retry_counter()

    retry_fn = fn _model, _msgs, on_chunk, _opts ->
      count = next_count(counter)

      if count < 1 do
        {:error, {:timeout, {GenServer, :call, [self(), {:next, 30_000}, 31_000]}}}
      else
        on_chunk.("ok")
        {:ok, "ok", []}
      end
    end

    stream_id = conv.stream_id

    assert :ok =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               model_id: "test-model",
               stream_fn: retry_fn,
               backoff_ms: 1
             )

    Agent.stop(counter)

    events = Store.read_stream_forward(stream_id)
    event_types = Enum.map(events, & &1.event_type)
    assert "AssistantStreamCompleted" in event_types
  end

  test "fails immediately on RuntimeError (Finch pool exhaustion) without retrying",
       %{conversation: conv} do
    stream_id = conv.stream_id

    fail_fn = fn _model, _msgs, _on_chunk, _opts ->
      {:error,
       %RuntimeError{
         message: "Finch was unable to provide a connection within the timeout"
       }}
    end

    assert {:error, _} =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               model_id: "test-model",
               stream_fn: fail_fn
             )

    events = Store.read_stream_forward(stream_id)
    failed = Enum.find(events, &(&1.event_type == "AssistantStreamFailed"))
    assert failed
    assert failed.data["retry_count"] == 0
    assert failed.data["error_message"] =~ "Finch was unable to provide a connection"
  end

  test "passes tools as ReqLLM.Tool structs in call_opts", %{conversation: conv} do
    stream_id = conv.stream_id

    tools = [
      %{
        "toolSpec" => %{
          "name" => "get_weather",
          "description" => "Get weather",
          "inputSchema" => %{"json" => %{"type" => "object"}}
        }
      }
    ]

    assert :ok =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               model_id: "test-model",
               tools: tools,
               stream_fn: fn _model, _msgs, _cb, opts ->
                 req_tools = Keyword.get(opts, :tools, [])
                 assert length(req_tools) == 1
                 assert %ReqLLM.Tool{} = hd(req_tools)
                 assert hd(req_tools).name == "get_weather"
                 {:ok, "", []}
               end
             )
  end

  test "omits api_key from provider_options when no bearer token configured", %{
    conversation: conv
  } do
    original = Application.get_env(:liteskill, Liteskill.LLM, [])
    Application.put_env(:liteskill, Liteskill.LLM, bedrock_region: "us-east-1")

    stream_id = conv.stream_id

    try do
      assert :ok =
               StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
                 model_id: "test-model",
                 stream_fn: fn _model, _msgs, _cb, opts ->
                   provider_opts = Keyword.get(opts, :provider_options, [])
                   refute Keyword.has_key?(provider_opts, :api_key)
                   {:ok, "", []}
                 end
               )
    after
      Application.put_env(:liteskill, Liteskill.LLM, original)
    end
  end

  test "stream without tools does not include tools in call_opts", %{conversation: conv} do
    stream_id = conv.stream_id

    assert :ok =
             StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
               model_id: "test-model",
               stream_fn: fn _model, _msgs, _cb, opts ->
                 assert Keyword.get(opts, :tools) == nil
                 {:ok, "", []}
               end
             )
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

  describe "tool-calling path" do
    setup %{conversation: conv} do
      on_exit(fn ->
        Process.delete(:stream_fn_round)
        Process.delete(:fake_tool_results)
      end)

      %{stream_id: conv.stream_id}
    end

    test "auto_confirm executes tool and continues to next round", %{stream_id: stream_id} do
      tool_use_id = "toolu_#{System.unique_integer([:positive])}"

      tool_calls = [%{tool_use_id: tool_use_id, name: "get_weather", input: %{"city" => "NYC"}}]

      tools = [
        %{"toolSpec" => %{"name" => "get_weather", "description" => "Get weather"}}
      ]

      assert :ok =
               StreamHandler.handle_stream(
                 stream_id,
                 [%{role: :user, content: "What's the weather?"}],
                 model_id: "test-model",
                 stream_fn: tool_call_stream_fn("Let me check that.", tool_calls),
                 tools: tools,
                 tool_servers: %{"get_weather" => %{builtin: FakeToolServer}},
                 auto_confirm: true
               )

      events = Store.read_stream_forward(stream_id)
      event_types = Enum.map(events, & &1.event_type)

      assert "ToolCallStarted" in event_types
      assert "ToolCallCompleted" in event_types
      assert Enum.count(event_types, &(&1 == "AssistantStreamStarted")) == 2
      assert Enum.count(event_types, &(&1 == "AssistantStreamCompleted")) == 2

      completions = Enum.filter(events, &(&1.event_type == "AssistantStreamCompleted"))
      assert hd(completions).data["stop_reason"] == "tool_use"
      assert List.last(completions).data["stop_reason"] == "end_turn"
    end

    test "auto_confirm records tool call with correct input and output", %{stream_id: stream_id} do
      tool_use_id = "toolu_#{System.unique_integer([:positive])}"

      tool_calls = [%{tool_use_id: tool_use_id, name: "search", input: %{"q" => "elixir"}}]

      Process.put(:fake_tool_results, %{
        "search" => {:ok, %{"content" => [%{"text" => "Elixir is great"}]}}
      })

      tools = [%{"toolSpec" => %{"name" => "search", "description" => "Search"}}]

      assert :ok =
               StreamHandler.handle_stream(stream_id, [%{role: :user, content: "search"}],
                 model_id: "test-model",
                 stream_fn: tool_call_stream_fn("Let me search.", tool_calls),
                 tools: tools,
                 tool_servers: %{"search" => %{builtin: FakeToolServer}},
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

      tool_calls = [%{tool_use_id: tool_use_id, name: "forbidden_tool", input: %{}}]

      tools = [%{"toolSpec" => %{"name" => "allowed_tool", "description" => "ok"}}]

      assert :ok =
               StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
                 model_id: "test-model",
                 stream_fn: fn _m, _ms, _cb, _o -> {:ok, "", tool_calls} end,
                 tools: tools,
                 auto_confirm: true
               )

      events = Store.read_stream_forward(stream_id)
      event_types = Enum.map(events, & &1.event_type)

      refute "ToolCallStarted" in event_types
      assert "AssistantStreamCompleted" in event_types
    end

    test "handles tool execution error", %{stream_id: stream_id} do
      tool_use_id = "toolu_#{System.unique_integer([:positive])}"

      tool_calls = [%{tool_use_id: tool_use_id, name: "failing_tool", input: %{}}]
      Process.put(:fake_tool_results, %{"failing_tool" => {:error, "connection timeout"}})

      tools = [%{"toolSpec" => %{"name" => "failing_tool", "description" => "Fails"}}]

      assert :ok =
               StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
                 model_id: "test-model",
                 stream_fn: tool_call_stream_fn("", tool_calls),
                 tools: tools,
                 tool_servers: %{"failing_tool" => %{builtin: FakeToolServer}},
                 auto_confirm: true
               )

      events = Store.read_stream_forward(stream_id)

      tc_completed = Enum.find(events, &(&1.event_type == "ToolCallCompleted"))
      assert tc_completed.data["output"]["error"] =~ "tool execution failed: "
      assert tc_completed.data["output"]["error"] =~ "connection timeout"
    end

    test "tool server nil returns error for unconfigured tool", %{stream_id: stream_id} do
      tool_use_id = "toolu_#{System.unique_integer([:positive])}"

      tool_calls = [%{tool_use_id: tool_use_id, name: "no_server_tool", input: %{}}]

      tools = [%{"toolSpec" => %{"name" => "no_server_tool", "description" => "No server"}}]

      assert :ok =
               StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
                 model_id: "test-model",
                 stream_fn: tool_call_stream_fn("", tool_calls),
                 tools: tools,
                 auto_confirm: true
               )

      events = Store.read_stream_forward(stream_id)
      tc_completed = Enum.find(events, &(&1.event_type == "ToolCallCompleted"))
      assert tc_completed.data["output"]["error"] =~ "tool execution failed: "
    end

    test "manual confirm rejects tool calls on timeout", %{stream_id: stream_id} do
      tool_use_id = "toolu_#{System.unique_integer([:positive])}"

      tool_calls = [%{tool_use_id: tool_use_id, name: "slow_tool", input: %{}}]

      tools = [%{"toolSpec" => %{"name" => "slow_tool", "description" => "Slow"}}]

      assert :ok =
               StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
                 model_id: "test-model",
                 stream_fn: tool_call_stream_fn("", tool_calls),
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

      tool_calls = [%{tool_use_id: tool_use_id, name: "approved_tool", input: %{}}]

      tools = [%{"toolSpec" => %{"name" => "approved_tool", "description" => "Will be approved"}}]

      approval_topic = "tool_approval:#{stream_id}"
      test_pid = self()

      # Subscribe to event store topic so the approver can wait for the
      # ToolCallStarted event instead of blindly sleeping
      spawn(fn ->
        Phoenix.PubSub.subscribe(Liteskill.PubSub, "event_store:#{stream_id}")
        send(test_pid, :approver_subscribed)

        # Drain event batches until we see ToolCallStarted
        wait = fn wait ->
          receive do
            {:events, _, events} ->
              if !Enum.any?(events, &(&1.event_type == "ToolCallStarted")) do
                wait.(wait)
              end
          after
            5000 -> :timeout
          end
        end

        wait.(wait)

        Phoenix.PubSub.broadcast(
          Liteskill.PubSub,
          approval_topic,
          {:tool_decision, tool_use_id, :approved}
        )

        send(test_pid, :approval_sent)
      end)

      # Ensure the approver is subscribed before starting the stream
      assert_receive :approver_subscribed, 1000

      assert :ok =
               StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
                 model_id: "test-model",
                 stream_fn: tool_call_stream_fn("", tool_calls),
                 tools: tools,
                 tool_servers: %{"approved_tool" => %{builtin: FakeToolServer}},
                 auto_confirm: false,
                 tool_approval_timeout_ms: 5000
               )

      assert_receive :approval_sent, 5000

      events = Store.read_stream_forward(stream_id)
      event_types = Enum.map(events, & &1.event_type)

      assert "ToolCallStarted" in event_types
      assert "ToolCallCompleted" in event_types

      tc_completed = Enum.find(events, &(&1.event_type == "ToolCallCompleted"))
      refute tc_completed.data["output"]["error"]
    end

    test "records text chunks via on_text_chunk callback", %{stream_id: stream_id} do
      assert :ok =
               StreamHandler.handle_stream(stream_id, [%{role: :user, content: "test"}],
                 model_id: "test-model",
                 stream_fn: text_chunks_stream_fn(["Hello ", "world!"])
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
        StreamHandler.format_tool_output({:ok, %{"content" => [%{"text" => "line1"}, %{"text" => "line2"}]}})

      assert result == "line1\nline2"
    end

    test "formats non-text content items as JSON" do
      result =
        StreamHandler.format_tool_output({:ok, %{"content" => [%{"image" => "data"}]}})

      assert result == ~s({"image":"data"})
    end

    test "formats plain map as JSON" do
      result = StreamHandler.format_tool_output({:ok, %{"key" => "value"}})
      assert result == ~s({"key":"value"})
    end

    test "formats non-map data with inspect" do
      result = StreamHandler.format_tool_output({:ok, 42})
      assert result == "42"
    end

    test "formats error tuple with sanitized message" do
      result = StreamHandler.format_tool_output({:error, "timeout"})
      assert result == "Error: tool execution failed"
    end
  end

  describe "extract_error_message/1" do
    test "extracts message from response_body map (ReqLLM struct pattern)" do
      error = %{status: 400, response_body: %{"message" => "Tool use not supported in streaming"}}

      assert StreamHandler.extract_error_message(error) ==
               "HTTP 400: Tool use not supported in streaming"
    end

    test "extracts Message key from response_body (AWS capitalization)" do
      error = %{status: 400, response_body: %{"Message" => "Invalid model"}}
      assert StreamHandler.extract_error_message(error) == "HTTP 400: Invalid model"
    end

    test "JSON-encodes response_body when no message key" do
      error = %{status: 400, response_body: %{"code" => "ValidationException"}}
      result = StreamHandler.extract_error_message(error)
      assert result =~ "HTTP 400:"
      assert result =~ "ValidationException"
    end

    test "extracts HTTP status and body string" do
      assert StreamHandler.extract_error_message(%{status: 403, body: "Access denied"}) ==
               "HTTP 403: Access denied"
    end

    test "extracts HTTP status and body map with message key" do
      assert StreamHandler.extract_error_message(%{status: 500, body: %{"message" => "Internal"}}) ==
               "HTTP 500: Internal"
    end

    test "extracts HTTP status and body map without message key" do
      result =
        StreamHandler.extract_error_message(%{status: 422, body: %{"error" => "bad input"}})

      assert result =~ "HTTP 422:"
      assert result =~ "bad input"
    end

    test "extracts HTTP status without body" do
      assert StreamHandler.extract_error_message(%{status: 502}) == "HTTP 502"
    end

    test "extracts reason from map" do
      assert StreamHandler.extract_error_message(%{reason: "some error"}) == "some error"
    end

    test "extracts provider config message for missing api_key with parameter hint" do
      reason =
        ~s(Failed to build stream request: %ReqLLM.Error.Invalid.Parameter{parameter: ":api_key option or OPENROUTER_API_KEY env var"})

      assert StreamHandler.extract_error_message(%{reason: reason}) ==
               "Missing API key: configure :api_key option or OPENROUTER_API_KEY env var"
    end

    test "extracts provider config message for missing api_key without parameter hint" do
      reason = "Invalid.Parameter: api_key is required"

      assert StreamHandler.extract_error_message(%{reason: reason}) ==
               "Missing API key for the configured LLM provider. Check your provider settings."
    end

    test "passes through binary reason" do
      assert StreamHandler.extract_error_message("connection timeout") == "connection timeout"
    end

    test "converts atom reason" do
      assert StreamHandler.extract_error_message(:timeout) == "timeout"
    end

    test "handles GenServer call timeout tuples" do
      error = {:timeout, {GenServer, :call, [self(), {:next, 30_000}, 31_000]}}
      assert StreamHandler.extract_error_message(error) == "request timeout"
    end

    test "handles RuntimeError from Finch connection pool exhaustion" do
      error = %RuntimeError{
        message: "Finch was unable to provide a connection within the timeout due to excess queuing for connections."
      }

      assert StreamHandler.extract_error_message(error) =~
               "Finch was unable to provide a connection"
    end

    test "truncates long RuntimeError messages" do
      error = %RuntimeError{message: String.duplicate("x", 600)}
      result = StreamHandler.extract_error_message(error)
      assert String.ends_with?(result, "...")
      assert byte_size(result) <= 504
    end

    test "falls back for unknown types" do
      assert StreamHandler.extract_error_message({:weird, :tuple}) == "LLM request failed"
    end

    test "extracts HTTP status and body list" do
      result = StreamHandler.extract_error_message(%{status: 400, body: ["err1", "err2"]})
      assert result =~ "HTTP 400:"
      assert result =~ "err1"
    end

    test "extracts HTTP status with non-standard body type" do
      assert StreamHandler.extract_error_message(%{status: 500, body: 12_345}) == "HTTP 500"
    end

    test "handles Mint.TransportError" do
      error = %Mint.TransportError{reason: :timeout}
      assert StreamHandler.extract_error_message(error) == "connection error: timeout"
    end

    test "truncates long error messages" do
      long_message = String.duplicate("a", 600)
      error = %{status: 400, body: long_message}
      result = StreamHandler.extract_error_message(error)
      assert result =~ "HTTP 400:"
      assert String.ends_with?(result, "...")
      # 500 chars + "..." suffix, plus the "HTTP 400: " prefix
      assert byte_size(result) < byte_size(long_message)
    end
  end

  describe "retryable_error?/1" do
    test "returns true for HTTP 429" do
      assert StreamHandler.retryable_error?(%{status: 429})
    end

    test "returns true for HTTP 503" do
      assert StreamHandler.retryable_error?(%{status: 503})
    end

    test "returns true for HTTP 408" do
      assert StreamHandler.retryable_error?(%{status: 408})
    end

    test "returns true for Mint.TransportError" do
      assert StreamHandler.retryable_error?(%Mint.TransportError{reason: :timeout})
      assert StreamHandler.retryable_error?(%Mint.TransportError{reason: :closed})
    end

    test "returns true for structs/maps with reason: timeout" do
      # ReqLLM.Error.API.Request with status: nil but reason: "timeout"
      assert StreamHandler.retryable_error?(%Request{
               reason: "timeout",
               status: nil
             })

      assert StreamHandler.retryable_error?(%{reason: "timeout"})
      assert StreamHandler.retryable_error?(%{reason: :timeout})
      assert StreamHandler.retryable_error?(%{reason: "closed"})
      assert StreamHandler.retryable_error?(%{reason: :closed})
    end

    test "returns true for timeout/closed atoms" do
      assert StreamHandler.retryable_error?(:timeout)
      assert StreamHandler.retryable_error?(:closed)
      assert StreamHandler.retryable_error?(:econnrefused)
    end

    test "returns true for additional server error codes" do
      assert StreamHandler.retryable_error?(%{status: 500})
      assert StreamHandler.retryable_error?(%{status: 502})
      assert StreamHandler.retryable_error?(%{status: 504})
    end

    test "returns true for GenServer call timeout tuples" do
      assert StreamHandler.retryable_error?({:timeout, {GenServer, :call, [self(), {:next, 30_000}, 31_000]}})

      assert StreamHandler.retryable_error?({:timeout, :some_ref})
    end

    test "returns false for non-retryable errors" do
      refute StreamHandler.retryable_error?(%{status: 400})
      refute StreamHandler.retryable_error?(%{status: 403})
      refute StreamHandler.retryable_error?("some error")
      refute StreamHandler.retryable_error?({:weird, :tuple})

      refute StreamHandler.retryable_error?(%RuntimeError{
               message: "Finch was unable to provide a connection"
             })
    end
  end

  describe "to_req_llm_model/1" do
    test "returns map-based model spec with amazon_bedrock provider" do
      assert StreamHandler.to_req_llm_model("us.anthropic.claude-3-5-sonnet-20241022-v2:0") ==
               %{id: "us.anthropic.claude-3-5-sonnet-20241022-v2:0", provider: :amazon_bedrock}
    end

    test "works with any model id" do
      assert StreamHandler.to_req_llm_model("custom-model") ==
               %{id: "custom-model", provider: :amazon_bedrock}
    end

    test "converts LlmModel struct to model spec" do
      llm_model = %LlmModel{
        model_id: "gpt-4o",
        provider: %LlmProvider{provider_type: "openai"}
      }

      assert StreamHandler.to_req_llm_model(llm_model) == %{id: "gpt-4o", provider: :openai}
    end
  end

  describe "usage recording" do
    test "records usage when user_id and usage are present", %{
      user: user,
      conversation: conv
    } do
      usage = %{
        input_tokens: 100,
        output_tokens: 50,
        total_tokens: 150,
        reasoning_tokens: 0,
        cached_tokens: 10,
        cache_creation_tokens: 5,
        input_cost: 0.003,
        output_cost: 0.0075,
        total_cost: 0.0105
      }

      assert :ok =
               StreamHandler.handle_stream(
                 conv.stream_id,
                 [%{role: :user, content: "test"}],
                 model_id: "test-model",
                 user_id: user.id,
                 conversation_id: conv.id,
                 stream_fn: text_stream_fn_with_usage("Hello!", usage)
               )

      records = Liteskill.Repo.all(UsageRecord)
      assert length(records) == 1

      record = hd(records)
      assert record.user_id == user.id
      assert record.conversation_id == conv.id
      assert record.model_id == "test-model"
      assert record.input_tokens == 100
      assert record.output_tokens == 50
      assert record.total_tokens == 150
      assert record.call_type == "stream"
    end

    test "does not record usage when user_id is missing", %{conversation: conv} do
      usage = %{input_tokens: 10, output_tokens: 5, total_tokens: 15}

      assert :ok =
               StreamHandler.handle_stream(
                 conv.stream_id,
                 [%{role: :user, content: "test"}],
                 model_id: "test-model",
                 stream_fn: text_stream_fn_with_usage("Hi", usage)
               )

      assert Liteskill.Repo.all(UsageRecord) == []
    end

    test "does not record usage when usage is nil (3-tuple)", %{
      user: user,
      conversation: conv
    } do
      assert :ok =
               StreamHandler.handle_stream(
                 conv.stream_id,
                 [%{role: :user, content: "test"}],
                 model_id: "test-model",
                 user_id: user.id,
                 conversation_id: conv.id,
                 stream_fn: text_stream_fn("Hello!")
               )

      assert Liteskill.Repo.all(UsageRecord) == []
    end

    test "populates input_tokens and output_tokens on AssistantStreamCompleted event", %{
      conversation: conv
    } do
      usage = %{input_tokens: 200, output_tokens: 80, total_tokens: 280}

      assert :ok =
               StreamHandler.handle_stream(
                 conv.stream_id,
                 [%{role: :user, content: "test"}],
                 model_id: "test-model",
                 stream_fn: text_stream_fn_with_usage("Hi", usage)
               )

      events = Store.read_stream_forward(conv.stream_id)
      completed = Enum.find(events, &(&1.event_type == "AssistantStreamCompleted"))
      assert completed.data["input_tokens"] == 200
      assert completed.data["output_tokens"] == 80
    end

    test "records usage with llm_model model_id", %{user: user, conversation: conv} do
      llm_model = %LlmModel{
        model_id: "claude-custom",
        provider: %LlmProvider{
          provider_type: "anthropic",
          api_key: "test-key",
          provider_config: %{}
        }
      }

      usage = %{input_tokens: 50, output_tokens: 25, total_tokens: 75}

      assert :ok =
               StreamHandler.handle_stream(
                 conv.stream_id,
                 [%{role: :user, content: "test"}],
                 llm_model: llm_model,
                 user_id: user.id,
                 conversation_id: conv.id,
                 stream_fn: fn _model_id, _msgs, _cb, _opts ->
                   {:ok, "ok", [], usage}
                 end
               )

      records = Liteskill.Repo.all(UsageRecord)
      assert length(records) == 1
      assert hd(records).model_id == "claude-custom"
    end

    test "calculates costs from model rates when API returns no costs", %{
      user: user,
      conversation: conv
    } do
      llm_model = %LlmModel{
        model_id: "claude-rated",
        input_cost_per_million: Decimal.new("3"),
        output_cost_per_million: Decimal.new("15"),
        provider: %LlmProvider{
          provider_type: "anthropic",
          api_key: "test-key",
          provider_config: %{}
        }
      }

      usage = %{input_tokens: 1_000_000, output_tokens: 500_000, total_tokens: 1_500_000}

      assert :ok =
               StreamHandler.handle_stream(
                 conv.stream_id,
                 [%{role: :user, content: "test"}],
                 llm_model: llm_model,
                 user_id: user.id,
                 conversation_id: conv.id,
                 stream_fn: fn _model_id, _msgs, _cb, _opts ->
                   {:ok, "ok", [], usage}
                 end
               )

      records = Liteskill.Repo.all(UsageRecord)
      assert length(records) == 1

      record = hd(records)
      assert Decimal.equal?(record.input_cost, Decimal.new("3"))
      assert Decimal.equal?(record.output_cost, Decimal.new("7.5"))
      assert Decimal.equal?(record.total_cost, Decimal.new("10.5"))
    end

    test "prefers API costs over model rates", %{user: user, conversation: conv} do
      llm_model = %LlmModel{
        model_id: "claude-rated",
        input_cost_per_million: Decimal.new("3"),
        output_cost_per_million: Decimal.new("15"),
        provider: %LlmProvider{
          provider_type: "anthropic",
          api_key: "test-key",
          provider_config: %{}
        }
      }

      usage = %{
        input_tokens: 100,
        output_tokens: 50,
        total_tokens: 150,
        input_cost: 0.001,
        output_cost: 0.002,
        total_cost: 0.003
      }

      assert :ok =
               StreamHandler.handle_stream(
                 conv.stream_id,
                 [%{role: :user, content: "test"}],
                 llm_model: llm_model,
                 user_id: user.id,
                 conversation_id: conv.id,
                 stream_fn: text_stream_fn_with_usage("Hello!", usage)
               )

      records = Liteskill.Repo.all(UsageRecord)
      assert length(records) == 1

      record = hd(records)
      assert Decimal.equal?(record.total_cost, Decimal.from_float(0.003))
    end
  end

  describe "to_req_llm_context/1" do
    test "converts atom-key user message" do
      ctx = StreamHandler.to_req_llm_context([%{role: :user, content: "Hello"}])
      assert %ReqLLM.Context{} = ctx
      assert length(ctx.messages) == 1
      assert hd(ctx.messages).role == :user
    end

    test "converts atom-key assistant message" do
      ctx = StreamHandler.to_req_llm_context([%{role: :assistant, content: "Hi"}])
      assert %ReqLLM.Context{} = ctx
      assert hd(ctx.messages).role == :assistant
    end

    test "converts string-key user text blocks" do
      ctx =
        StreamHandler.to_req_llm_context([
          %{"role" => "user", "content" => [%{"text" => "Hello world"}]}
        ])

      assert %ReqLLM.Context{} = ctx
      assert length(ctx.messages) == 1
      assert hd(ctx.messages).role == :user
    end

    test "converts string-key simple text content" do
      ctx =
        StreamHandler.to_req_llm_context([
          %{"role" => "user", "content" => "plain text"},
          %{"role" => "assistant", "content" => "response"}
        ])

      assert length(ctx.messages) == 2
    end

    test "converts string-key assistant with toolUse blocks" do
      ctx =
        StreamHandler.to_req_llm_context([
          %{
            "role" => "assistant",
            "content" => [
              %{"text" => "Let me search."},
              %{
                "toolUse" => %{
                  "toolUseId" => "tc-1",
                  "name" => "search",
                  "input" => %{"q" => "test"}
                }
              }
            ]
          }
        ])

      assert %ReqLLM.Context{} = ctx
      msg = hd(ctx.messages)
      assert msg.role == :assistant
    end

    test "converts string-key assistant without toolUse blocks" do
      ctx =
        StreamHandler.to_req_llm_context([
          %{"role" => "assistant", "content" => [%{"text" => "Just text"}]}
        ])

      assert hd(ctx.messages).role == :assistant
    end

    test "converts string-key user toolResult blocks" do
      ctx =
        StreamHandler.to_req_llm_context([
          %{
            "role" => "user",
            "content" => [
              %{
                "toolResult" => %{
                  "toolUseId" => "tc-1",
                  "content" => [%{"text" => "Result text"}],
                  "status" => "success"
                }
              }
            ]
          }
        ])

      assert %ReqLLM.Context{} = ctx
      msg = hd(ctx.messages)
      assert msg.role == :tool
    end

    test "converts toolResult with non-text content" do
      ctx =
        StreamHandler.to_req_llm_context([
          %{
            "role" => "user",
            "content" => [
              %{
                "toolResult" => %{
                  "toolUseId" => "tc-1",
                  "content" => [%{"image" => "data"}],
                  "status" => "success"
                }
              }
            ]
          }
        ])

      assert length(ctx.messages) == 1
    end

    test "converts toolResult with missing content" do
      ctx =
        StreamHandler.to_req_llm_context([
          %{
            "role" => "user",
            "content" => [
              %{
                "toolResult" => %{
                  "toolUseId" => "tc-1",
                  "status" => "success"
                }
              }
            ]
          }
        ])

      assert length(ctx.messages) == 1
    end

    test "handles assistant toolUse with nil input" do
      ctx =
        StreamHandler.to_req_llm_context([
          %{
            "role" => "assistant",
            "content" => [
              %{
                "toolUse" => %{
                  "toolUseId" => "tc-1",
                  "name" => "tool",
                  "input" => nil
                }
              }
            ]
          }
        ])

      assert length(ctx.messages) == 1
    end
  end

  describe "cost limit guardrail" do
    test "blocks stream when conversation cost exceeds limit", %{
      user: user,
      conversation: conv
    } do
      # Record usage that exceeds $1 limit
      Liteskill.Usage.record_usage(%{
        user_id: user.id,
        conversation_id: conv.id,
        model_id: "test-model",
        input_tokens: 100,
        output_tokens: 50,
        total_tokens: 150,
        input_cost: Decimal.new("0.80"),
        output_cost: Decimal.new("0.30"),
        total_cost: Decimal.new("1.10"),
        latency_ms: 100,
        call_type: "stream",
        tool_round: 0
      })

      result =
        StreamHandler.handle_stream(
          conv.stream_id,
          [%{role: :user, content: "test"}],
          model_id: "test-model",
          stream_fn: text_stream_fn("Should not appear"),
          cost_limit: Decimal.new("1.00"),
          conversation_id: conv.id
        )

      assert {:error, {"cost_limit", msg}} = result
      assert msg =~ "Cost limit of $1"
      assert msg =~ "spent"
    end

    test "allows stream when cost is under limit", %{user: user, conversation: conv} do
      # Record small usage
      Liteskill.Usage.record_usage(%{
        user_id: user.id,
        conversation_id: conv.id,
        model_id: "test-model",
        input_tokens: 10,
        output_tokens: 5,
        total_tokens: 15,
        input_cost: Decimal.new("0.001"),
        output_cost: Decimal.new("0.001"),
        total_cost: Decimal.new("0.002"),
        latency_ms: 100,
        call_type: "stream",
        tool_round: 0
      })

      assert :ok =
               StreamHandler.handle_stream(
                 conv.stream_id,
                 [%{role: :user, content: "test"}],
                 model_id: "test-model",
                 stream_fn: text_stream_fn("Hello!"),
                 cost_limit: Decimal.new("10.00"),
                 conversation_id: conv.id
               )
    end

    test "skips cost check when cost_limit is nil", %{conversation: conv} do
      assert :ok =
               StreamHandler.handle_stream(
                 conv.stream_id,
                 [%{role: :user, content: "test"}],
                 model_id: "test-model",
                 stream_fn: text_stream_fn("Hello!"),
                 cost_limit: nil,
                 conversation_id: conv.id
               )
    end

    test "skips cost check when conversation_id is nil", %{conversation: conv} do
      assert :ok =
               StreamHandler.handle_stream(
                 conv.stream_id,
                 [%{role: :user, content: "test"}],
                 model_id: "test-model",
                 stream_fn: text_stream_fn("Hello!"),
                 cost_limit: Decimal.new("1.00")
               )
    end

    test "checks cost limit between tool-call rounds and continues when under limit", %{
      user: user,
      conversation: conv
    } do
      on_exit(fn -> Process.delete(:stream_fn_round) end)

      tool_use_id = "toolu_#{System.unique_integer([:positive])}"
      tool_calls = [%{tool_use_id: tool_use_id, name: "search", input: %{"q" => "test"}}]
      tools = [%{"toolSpec" => %{"name" => "search", "description" => "Search"}}]

      assert :ok =
               StreamHandler.handle_stream(
                 conv.stream_id,
                 [%{role: :user, content: "test"}],
                 model_id: "test-model",
                 stream_fn: tool_call_stream_fn("Searching.", tool_calls),
                 tools: tools,
                 tool_servers: %{"search" => %{builtin: FakeToolServer}},
                 auto_confirm: true,
                 cost_limit: Decimal.new("100.00"),
                 conversation_id: conv.id,
                 user_id: user.id
               )

      events = Store.read_stream_forward(conv.stream_id)
      event_types = Enum.map(events, & &1.event_type)
      assert "ToolCallCompleted" in event_types
      assert Enum.count(event_types, &(&1 == "AssistantStreamCompleted")) == 2
    end

    test "stops tool-call loop when cost limit exceeded between rounds", %{
      user: user,
      conversation: conv
    } do
      on_exit(fn -> Process.delete(:stream_fn_round) end)

      tool_use_id = "toolu_#{System.unique_integer([:positive])}"
      tool_calls = [%{tool_use_id: tool_use_id, name: "search", input: %{"q" => "test"}}]
      tools = [%{"toolSpec" => %{"name" => "search", "description" => "Search"}}]

      # First round returns tool calls + usage that will exceed the $0.0001 limit.
      # The initial cost check passes ($0 spent), but after the first round records
      # usage via complete_stream_with_stop_reason → maybe_record_usage, the
      # between-rounds check catches the exceeded limit.
      usage = %{
        input_tokens: 1_000_000,
        output_tokens: 500_000,
        total_tokens: 1_500_000,
        input_cost: 1.0,
        output_cost: 1.0,
        total_cost: 2.0
      }

      stream_fn = fn _model_id, _messages, on_chunk, _opts ->
        round = Process.get(:stream_fn_round, 0)
        Process.put(:stream_fn_round, round + 1)

        if round == 0 do
          on_chunk.("Searching.")
          {:ok, "Searching.", tool_calls, usage}
        else
          on_chunk.("Done.")
          {:ok, "Done.", []}
        end
      end

      llm_model = %LlmModel{
        model_id: "test-model",
        provider: %LlmProvider{
          provider_type: "anthropic",
          api_key: "test-key",
          provider_config: %{}
        }
      }

      assert {:error, :cost_limit_exceeded} =
               StreamHandler.handle_stream(
                 conv.stream_id,
                 [%{role: :user, content: "test"}],
                 llm_model: llm_model,
                 stream_fn: stream_fn,
                 tools: tools,
                 tool_servers: %{"search" => %{builtin: FakeToolServer}},
                 auto_confirm: true,
                 cost_limit: Decimal.new("0.0001"),
                 conversation_id: conv.id,
                 user_id: user.id
               )
    end
  end

  describe "retryable_error_label/1" do
    test "returns transient error for unexpected string" do
      assert StreamHandler.retryable_error_label("unexpected string") == "transient error"
    end
  end

  describe "max_output_tokens fallback" do
    test "uses model max_output_tokens when no max_tokens in opts", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})
      {:ok, _msg} = Chat.send_message(conv.id, user.id, "test")

      # Create model with max_output_tokens
      {:ok, provider} =
        Liteskill.LlmProviders.create_provider(%{
          name: "Fallback Provider #{System.unique_integer([:positive])}",
          provider_type: "anthropic",
          api_key: "test-key",
          user_id: user.id
        })

      {:ok, model} =
        Liteskill.LlmModels.create_model(%{
          name: "Fallback Model #{System.unique_integer([:positive])}",
          model_id: "test-model",
          provider_id: provider.id,
          user_id: user.id,
          max_output_tokens: 4096,
          instance_wide: true
        })

      captured_opts = fn -> nil end |> Agent.start_link() |> elem(1)

      stream_fn = fn _model, _messages, _on_chunk, opts ->
        Agent.update(captured_opts, fn _ -> opts end)
        {:ok, "done", []}
      end

      llm_model = Liteskill.LlmModels.get_model!(model.id)

      StreamHandler.handle_stream(
        conv.stream_id,
        [%{role: :user, content: "test"}],
        llm_model: llm_model,
        stream_fn: stream_fn,
        skip_gateway: true,
        user_id: user.id,
        conversation_id: conv.id
      )

      opts = Agent.get(captured_opts, & &1)
      assert opts[:max_tokens] == 4096
    end
  end

  describe "check_context_size" do
    test "returns error when messages exceed context window", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})
      {:ok, _msg} = Chat.send_message(conv.id, user.id, "test")

      {:ok, provider} =
        Liteskill.LlmProviders.create_provider(%{
          name: "Context Provider #{System.unique_integer([:positive])}",
          provider_type: "anthropic",
          api_key: "test-key",
          user_id: user.id
        })

      {:ok, model} =
        Liteskill.LlmModels.create_model(%{
          name: "Context Model #{System.unique_integer([:positive])}",
          model_id: "test-model-ctx",
          provider_id: provider.id,
          user_id: user.id,
          context_window: 100,
          instance_wide: true
        })

      llm_model = Liteskill.LlmModels.get_model!(model.id)

      # Create messages that exceed 95% of 100 tokens (i.e. > 95 tokens ~ 380 bytes)
      large_content = String.duplicate("x", 500)

      result =
        StreamHandler.handle_stream(
          conv.stream_id,
          [%{role: :user, content: large_content}],
          llm_model: llm_model,
          stream_fn: fn _, _, _ -> {:ok, []} end,
          skip_gateway: true,
          user_id: user.id,
          conversation_id: conv.id
        )

      assert {:error, {"context_too_large", _}} = result
    end

    test "passes when model has no context_window", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})
      {:ok, _msg} = Chat.send_message(conv.id, user.id, "test")

      {:ok, provider} =
        Liteskill.LlmProviders.create_provider(%{
          name: "NoCtx Provider #{System.unique_integer([:positive])}",
          provider_type: "anthropic",
          api_key: "test-key",
          user_id: user.id
        })

      {:ok, model} =
        Liteskill.LlmModels.create_model(%{
          name: "NoCtx Model #{System.unique_integer([:positive])}",
          model_id: "test-model-noctx",
          provider_id: provider.id,
          user_id: user.id,
          instance_wide: true
        })

      llm_model = Liteskill.LlmModels.get_model!(model.id)

      stream_fn = fn _model, _messages, on_chunk, _opts ->
        on_chunk.("ok")
        {:ok, "ok", []}
      end

      assert :ok =
               StreamHandler.handle_stream(
                 conv.stream_id,
                 [%{role: :user, content: String.duplicate("x", 500)}],
                 llm_model: llm_model,
                 stream_fn: stream_fn,
                 skip_gateway: true,
                 user_id: user.id,
                 conversation_id: conv.id
               )
    end

    test "handles list and map content in messages", %{user: user} do
      {:ok, conv} = Chat.create_conversation(%{user_id: user.id})
      {:ok, _msg} = Chat.send_message(conv.id, user.id, "test")

      {:ok, provider} =
        Liteskill.LlmProviders.create_provider(%{
          name: "ListMap Provider #{System.unique_integer([:positive])}",
          provider_type: "anthropic",
          api_key: "test-key",
          user_id: user.id
        })

      {:ok, model} =
        Liteskill.LlmModels.create_model(%{
          name: "ListMap Model #{System.unique_integer([:positive])}",
          model_id: "test-model-listmap",
          provider_id: provider.id,
          user_id: user.id,
          context_window: 100_000,
          instance_wide: true
        })

      llm_model = Liteskill.LlmModels.get_model!(model.id)

      stream_fn = fn _model, _messages, on_chunk, _opts ->
        on_chunk.("ok")
        {:ok, "ok", []}
      end

      # Messages with list and map content types
      messages = [
        %{role: :user, content: [%{type: "text", text: "hello"}]},
        %{role: :user, content: %{type: "text", text: "world"}},
        %{role: :user, content: 12_345}
      ]

      assert :ok =
               StreamHandler.handle_stream(
                 conv.stream_id,
                 messages,
                 llm_model: llm_model,
                 stream_fn: stream_fn,
                 skip_gateway: true,
                 user_id: user.id,
                 conversation_id: conv.id
               )
    end
  end

  defmodule BareStatusError do
    @moduledoc false
    defstruct [:status]
  end

  defmodule StatusBodyError do
    @moduledoc false
    defstruct [:status, :body]
  end

  describe "normalize_error/1" do
    test "passes through plain map with status" do
      error = %{status: 429, body: "rate limited"}
      assert StreamHandler.normalize_error(error) == error
    end

    test "extracts status and response_body from struct" do
      error =
        Request.exception(
          status: 500,
          response_body: %{"error" => "server error"},
          reason: "server error"
        )

      result = StreamHandler.normalize_error(error)
      assert result == %{status: 500, body: %{"error" => "server error"}}
    end

    test "passes through struct without integer status" do
      error = %RuntimeError{message: "boom"}
      assert StreamHandler.normalize_error(error) == error
    end

    test "unwraps nested error tuple {outer, {inner, struct}}" do
      inner_error =
        Request.exception(
          status: 503,
          response_body: %{"error" => "unavailable"},
          reason: "unavailable"
        )

      wrapped = {:http_streaming_failed, {:provider_build_failed, inner_error}}
      result = StreamHandler.normalize_error(wrapped)
      assert result == %{status: 503, body: %{"error" => "unavailable"}}
    end

    test "unwraps single-level error tuple {outer, struct}" do
      inner_error =
        Request.exception(
          status: 502,
          response_body: %{"error" => "bad gateway"},
          reason: "bad gateway"
        )

      wrapped = {:streaming_failed, inner_error}
      result = StreamHandler.normalize_error(wrapped)
      assert result == %{status: 502, body: %{"error" => "bad gateway"}}
    end

    test "passes through unrecognized error format" do
      assert StreamHandler.normalize_error(:timeout) == :timeout
      assert StreamHandler.normalize_error("string error") == "string error"
    end

    test "extracts body from struct with :body key" do
      error = %StatusBodyError{status: 422, body: "validation failed"}
      result = StreamHandler.normalize_error(error)
      assert result == %{status: 422, body: "validation failed"}
    end

    test "extracts reason when no response_body or body" do
      error =
        Request.exception(
          status: 408,
          reason: "timeout"
        )

      result = StreamHandler.normalize_error(error)
      assert result == %{status: 408, body: "timeout"}
    end

    test "falls back to default message for struct with only status" do
      error = %BareStatusError{status: 500}
      result = StreamHandler.normalize_error(error)
      assert result == %{status: 500, body: "LLM request failed"}
    end
  end

  describe "extract_provider_id/1" do
    test "extracts provider_id from llm_model" do
      assert StreamHandler.extract_provider_id(llm_model: %{provider_id: "prov-123"}) ==
               "prov-123"
    end

    test "extracts provider id from nested provider struct" do
      assert StreamHandler.extract_provider_id(llm_model: %{provider: %{id: "prov-456"}}) ==
               "prov-456"
    end

    test "returns nil when no llm_model" do
      assert StreamHandler.extract_provider_id([]) == nil
    end

    test "returns nil when llm_model has no provider_id" do
      assert StreamHandler.extract_provider_id(llm_model: %{name: "test"}) == nil
    end
  end

  describe "gateway_checkin/2" do
    test "calls ProviderGate.checkin when provider_id and ref present" do
      # Start a real ProviderGate for this test
      provider_id = "checkin-test-#{System.unique_integer([:positive])}"
      {:ok, ref} = ProviderGate.checkout(provider_id)

      opts = [gateway_provider_id: provider_id, gateway_checkout_ref: ref]
      assert StreamHandler.gateway_checkin(opts, :ok) == :ok
    end

    test "does nothing when no provider_id" do
      assert StreamHandler.gateway_checkin([], :ok) == nil
    end

    test "does nothing when no ref" do
      assert StreamHandler.gateway_checkin([gateway_provider_id: "prov-1"], :ok) == nil
    end
  end

  describe "format_tool_error/1" do
    test "returns binary as-is" do
      assert StreamHandler.format_tool_error("something failed") == "something failed"
    end

    test "extracts message from exception" do
      err = %RuntimeError{message: "boom"}
      assert StreamHandler.format_tool_error(err) == "boom"
    end

    test "inspects other terms" do
      assert StreamHandler.format_tool_error({:error, :timeout}) == "{:error, :timeout}"
      assert StreamHandler.format_tool_error(42) == "42"
    end
  end

  describe "check_gateway/1" do
    test "skips gateway when skip_gateway: true" do
      assert {:ok, opts} = StreamHandler.check_gateway(skip_gateway: true)
      assert opts == [skip_gateway: true]
    end

    test "passes through when no user_id or model" do
      assert {:ok, _opts} = StreamHandler.check_gateway([])
    end

    test "passes through when user_id and model_id provided (no rate limit hit)" do
      assert {:ok, _opts} =
               StreamHandler.check_gateway(
                 user_id: Ecto.UUID.generate(),
                 llm_model: %{model_id: "test-model-#{System.unique_integer([:positive])}"}
               )
    end
  end

  describe "check_token_bucket/1" do
    test "returns :ok when no user_id" do
      assert :ok = StreamHandler.check_token_bucket([])
    end

    test "returns :ok when under rate limit" do
      assert :ok =
               StreamHandler.check_token_bucket(
                 user_id: Ecto.UUID.generate(),
                 llm_model: %{model_id: "bucket-test-#{System.unique_integer([:positive])}"}
               )
    end

    test "returns rate_limited error when over limit" do
      user_id = Ecto.UUID.generate()
      model_id = "rate-limit-test-#{System.unique_integer([:positive])}"

      # Exhaust the bucket (default 60 req/min)
      for _ <- 1..61 do
        Liteskill.LlmGateway.TokenBucket.check_rate(user_id, model_id)
      end

      assert {:error, {"rate_limited", _}} =
               StreamHandler.check_token_bucket(
                 user_id: user_id,
                 llm_model: %{model_id: model_id}
               )
    end
  end

  describe "check_provider_gate/1" do
    test "returns empty opts when no provider_id" do
      assert {:ok, []} = StreamHandler.check_provider_gate([])
    end

    test "returns checkout ref when provider_id found" do
      provider_id = "gate-test-#{System.unique_integer([:positive])}"

      assert {:ok, opts} =
               StreamHandler.check_provider_gate(llm_model: %{provider_id: provider_id})

      assert Keyword.has_key?(opts, :gateway_provider_id)
      assert Keyword.has_key?(opts, :gateway_checkout_ref)

      # Clean up: checkin
      StreamHandler.gateway_checkin(opts, :ok)
    end

    test "returns circuit_open error when circuit is tripped" do
      provider_id = "circuit-test-#{System.unique_integer([:positive])}"
      gate = ProviderGate

      # Trip the circuit: checkout+checkin with errors to trigger open state
      # Stop when circuit opens (checkout returns error)
      Enum.reduce_while(1..20, :ok, fn _, _ ->
        case gate.checkout(provider_id) do
          {:ok, ref} ->
            gate.checkin(provider_id, ref, {:error, :non_retryable})
            {:cont, :ok}

          {:error, :circuit_open, _} ->
            {:halt, :tripped}
        end
      end)

      assert {:error, {"circuit_open", _}} =
               StreamHandler.check_provider_gate(llm_model: %{provider_id: provider_id})
    end

    test "returns concurrency_limit error when all slots taken" do
      provider_id = "concurrency-test-#{System.unique_integer([:positive])}"
      gate = ProviderGate

      # Exhaust concurrency (default 25)
      refs =
        for _ <- 1..25 do
          {:ok, ref} = gate.checkout(provider_id)
          ref
        end

      assert {:error, {"concurrency_limit", _}} =
               StreamHandler.check_provider_gate(llm_model: %{provider_id: provider_id})

      # Clean up
      for ref <- refs, do: gate.checkin(provider_id, ref, :ok)
    end

    test "returns rate_limited error when retry_after is active" do
      provider_id = "retry-after-test-#{System.unique_integer([:positive])}"
      gate = ProviderGate

      {:ok, ref} = gate.checkout(provider_id)
      gate.checkin(provider_id, ref, {:error, :retryable, 60_000})

      assert {:error, {"rate_limited", _}} =
               StreamHandler.check_provider_gate(llm_model: %{provider_id: provider_id})
    end
  end
end
