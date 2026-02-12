defmodule Liteskill.LLM.StreamHandler do
  @moduledoc """
  Orchestrates streaming LLM calls with event store integration.

  Appends AssistantStreamStarted -> calls converse_stream with callback that
  appends AssistantChunkReceived per chunk -> appends AssistantStreamCompleted
  or AssistantStreamFailed. Includes retry with exponential backoff for 429/503.

  Supports tool calling: when Bedrock returns tool_use content blocks, records
  ToolCallStarted events. In auto-confirm mode, executes tools via MCP client
  and continues the conversation loop. Otherwise, completes with stop_reason="tool_use"
  for manual confirmation by the UI.
  """

  alias Liteskill.Aggregate.Loader
  alias Liteskill.Chat.{ConversationAggregate, Projector}
  alias Liteskill.McpServers.Client, as: McpClient

  require Logger

  @max_retries 3
  @max_tool_rounds 10
  @default_backoff_ms 1000
  @tool_approval_timeout_ms 300_000

  @doc """
  Handles a full streaming LLM call for a conversation.

  This is meant to be called asynchronously after a user message is added.

  ## Options

    * `:provider` - LLM provider module (default from config, falls back to `BedrockClient`)
    * `:model_id` - Model ID
    * `:system` - System prompt
    * `:tools` - List of toolConfig tool specs
    * `:tool_servers` - Map of `"tool_name" => server` for MCP execution
    * `:auto_confirm` - Boolean, auto-execute tool calls (default false)
    * `:plug` - Req.Test plug for testing
    * `:backoff_ms` - Base backoff for retries
    * `:tool_approval_timeout_ms` - Timeout for manual tool approval (default 300_000)
    * `:max_tool_rounds` - Max consecutive tool-calling rounds (default 10)
  """
  def handle_stream(stream_id, messages, opts \\ []) do
    tool_round = Keyword.get(opts, :tool_round, 0)
    max_rounds = Keyword.get(opts, :max_tool_rounds, @max_tool_rounds)

    if tool_round >= max_rounds do
      Logger.warning("StreamHandler: max tool rounds (#{max_rounds}) exceeded for #{stream_id}")
      {:error, :max_tool_rounds_exceeded}
    else
      do_handle_stream(stream_id, messages, opts)
    end
  end

  defp do_handle_stream(stream_id, messages, opts) do
    model_id = Keyword.get(opts, :model_id, default_model_id())
    message_id = Ecto.UUID.generate()
    rag_sources = Keyword.get(opts, :rag_sources)

    # Start the stream
    command =
      {:start_assistant_stream,
       %{message_id: message_id, model_id: model_id, rag_sources: rag_sources}}

    case Loader.execute(ConversationAggregate, stream_id, command) do
      {:ok, _state, events} ->
        Projector.project_events(stream_id, events)
        do_stream(stream_id, message_id, model_id, messages, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_stream(stream_id, message_id, model_id, messages, opts) do
    do_stream_with_retry(stream_id, message_id, model_id, messages, opts, 0)
  end

  defp do_stream_with_retry(stream_id, message_id, _model_id, _messages, _opts, retry_count)
       when retry_count >= @max_retries do
    fail_stream(
      stream_id,
      message_id,
      "max_retries_exceeded",
      "Exceeded #{@max_retries} retries",
      retry_count
    )
  end

  defp do_stream_with_retry(stream_id, message_id, model_id, messages, opts, retry_count) do
    start_time = System.monotonic_time(:millisecond)
    chunk_index = :counters.new(1, [:atomics])
    {:ok, text_agent} = Agent.start_link(fn -> [] end)
    {:ok, tool_calls_agent} = Agent.start_link(fn -> [] end)
    current_tool_ref = make_ref()
    Process.put(current_tool_ref, nil)

    callback = fn {event_type, payload} ->
      handle_stream_event(
        stream_id,
        message_id,
        chunk_index,
        text_agent,
        tool_calls_agent,
        current_tool_ref,
        event_type,
        payload
      )
    end

    system = Keyword.get(opts, :system)
    call_opts = if system, do: [system: system], else: []

    call_opts =
      Keyword.merge(call_opts, Keyword.take(opts, [:max_tokens, :temperature, :plug, :tools]))

    provider = Keyword.get(opts, :provider, default_provider())

    case provider.converse_stream(model_id, messages, callback, call_opts) do
      :ok ->
        latency_ms = System.monotonic_time(:millisecond) - start_time
        full_content = text_agent |> Agent.get(& &1) |> Enum.reverse() |> Enum.join("")
        tool_calls = Agent.get(tool_calls_agent, &Enum.reverse(&1))
        Agent.stop(text_agent)
        Agent.stop(tool_calls_agent)
        cleanup_tool_ref(current_tool_ref)

        if tool_calls != [] do
          handle_tool_calls(
            stream_id,
            message_id,
            model_id,
            messages,
            full_content,
            tool_calls,
            latency_ms,
            opts
          )
        else
          complete_stream(stream_id, message_id, full_content, latency_ms, opts)
        end

      {:error, %{status: status}} when status in [429, 503] ->
        Agent.stop(text_agent)
        Agent.stop(tool_calls_agent)
        cleanup_tool_ref(current_tool_ref)
        base_backoff = Keyword.get(opts, :backoff_ms, @default_backoff_ms)
        jitter = :rand.uniform()
        backoff = trunc(base_backoff * Integer.pow(2, retry_count) * (1 + jitter))
        Logger.warning("Bedrock #{status}, retrying in #{backoff}ms (attempt #{retry_count + 1})")
        Process.sleep(backoff)
        do_stream_with_retry(stream_id, message_id, model_id, messages, opts, retry_count + 1)

      {:error, reason} ->
        Agent.stop(text_agent)
        Agent.stop(tool_calls_agent)
        cleanup_tool_ref(current_tool_ref)
        error_msg = inspect(reason)
        fail_stream(stream_id, message_id, "request_error", error_msg, retry_count)
    end
  end

  defp handle_stream_event(
         stream_id,
         message_id,
         chunk_counter,
         text_agent,
         tool_calls_agent,
         _current_tool_ref,
         :content_block_delta,
         payload
       ) do
    delta = get_in(payload, ["delta"])

    cond do
      # Bedrock tool input delta: {"delta": {"toolUse": {"input": "..."}}}
      is_map(delta["toolUse"]) ->
        input_fragment = get_in(delta, ["toolUse", "input"])

        if input_fragment do
          fragment =
            if is_binary(input_fragment),
              do: input_fragment,
              else: Jason.encode!(input_fragment)

          Agent.update(tool_calls_agent, fn
            [] ->
              []

            [latest | rest] ->
              [%{latest | input_parts: [fragment | latest.input_parts]} | rest]
          end)
        end

      # Bedrock text delta: {"delta": {"text": "..."}}
      delta["text"] != nil ->
        delta_text = delta["text"]

        idx = :counters.get(chunk_counter, 1)
        :counters.add(chunk_counter, 1, 1)

        Agent.update(text_agent, fn parts -> [delta_text | parts] end)

        command =
          {:receive_chunk,
           %{
             message_id: message_id,
             chunk_index: idx,
             content_block_index: get_in(payload, ["contentBlockIndex"]) || 0,
             delta_type: "text_delta",
             delta_text: delta_text
           }}

        case Loader.execute(ConversationAggregate, stream_id, command) do
          {:ok, _state, events} -> Projector.project_events_async(stream_id, events)
          {:error, reason} -> Logger.error("Failed to record chunk: #{inspect(reason)}")
        end

      true ->
        :ok
    end
  end

  defp handle_stream_event(
         _stream_id,
         _message_id,
         _chunk_counter,
         _text_agent,
         tool_calls_agent,
         current_tool_ref,
         :content_block_start,
         payload
       ) do
    case get_in(payload, ["start", "toolUse"]) do
      %{"toolUseId" => tool_use_id, "name" => name} ->
        Process.put(current_tool_ref, %{
          tool_use_id: tool_use_id,
          name: name,
          input_parts: []
        })

        Agent.update(tool_calls_agent, fn calls ->
          [%{tool_use_id: tool_use_id, name: name, input_parts: []} | calls]
        end)

      _ ->
        :ok
    end
  end

  defp handle_stream_event(
         _stream_id,
         _message_id,
         _chunk_counter,
         _text_agent,
         _tool_calls_agent,
         _current_tool_ref,
         _event_type,
         _payload
       ) do
    :ok
  end

  @doc """
  Parses raw tool call accumulations (with input_parts as JSON fragments)
  into structured tool calls with decoded input maps.
  """
  def parse_tool_calls(tool_calls) do
    Enum.map(tool_calls, fn tc ->
      input_json = tc.input_parts |> Enum.reverse() |> Enum.join("")

      input =
        case Jason.decode(input_json) do
          {:ok, parsed} -> parsed
          _ -> %{}
        end

      %{tool_use_id: tc.tool_use_id, name: tc.name, input: input}
    end)
  end

  @doc """
  Filters tool calls to only include those whose names appear in the
  allowed tools list. Returns no tool calls if tools list is empty (deny-all).
  """
  def validate_tool_calls(tool_calls, tools) do
    allowed = tools |> Enum.map(&get_in(&1, ["toolSpec", "name"])) |> MapSet.new()

    if MapSet.size(allowed) == 0 do
      []
    else
      Enum.filter(tool_calls, &MapSet.member?(allowed, &1.name))
    end
  end

  @doc """
  Builds the assistant content blocks (text + toolUse) for the next
  conversation round after tool calls.
  """
  def build_assistant_content(full_content, tool_calls) do
    text_blocks =
      if full_content != "" do
        [%{"text" => full_content}]
      else
        []
      end

    tool_use_blocks =
      Enum.map(tool_calls, fn tc ->
        %{
          "toolUse" => %{
            "toolUseId" => tc.tool_use_id,
            "name" => tc.name,
            "input" => tc.input
          }
        }
      end)

    text_blocks ++ tool_use_blocks
  end

  @doc """
  Formats tool execution output into a string for inclusion in
  conversation messages.
  """
  def format_tool_output({:ok, %{"content" => content}}) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => text} -> text
      other -> Jason.encode!(other)
    end)
    |> Enum.join("\n")
  end

  def format_tool_output({:ok, data}) when is_map(data), do: Jason.encode!(data)
  def format_tool_output({:ok, data}), do: inspect(data)
  def format_tool_output({:error, err}), do: "Error: #{inspect(err)}"

  defp handle_tool_calls(
         stream_id,
         message_id,
         _model_id,
         messages,
         full_content,
         tool_calls,
         latency_ms,
         opts
       ) do
    # Parse accumulated input JSON for each tool call
    parsed_tool_calls = parse_tool_calls(tool_calls)

    # Filter to only allowed tools
    tools = Keyword.get(opts, :tools, [])
    parsed_tool_calls = validate_tool_calls(parsed_tool_calls, tools)

    # If all tool calls were filtered out, complete as a normal stream
    if parsed_tool_calls == [] do
      complete_stream(stream_id, message_id, full_content, latency_ms, opts)
    else
      do_handle_tool_calls(
        stream_id,
        message_id,
        messages,
        full_content,
        parsed_tool_calls,
        latency_ms,
        opts
      )
    end
  end

  defp do_handle_tool_calls(
         stream_id,
         message_id,
         messages,
         full_content,
         parsed_tool_calls,
         latency_ms,
         opts
       ) do
    # Record ToolCallStarted events for each tool call
    Enum.each(parsed_tool_calls, fn tc ->
      command =
        {:start_tool_call,
         %{
           message_id: message_id,
           tool_use_id: tc.tool_use_id,
           tool_name: tc.name,
           input: tc.input
         }}

      case Loader.execute(ConversationAggregate, stream_id, command) do
        {:ok, _state, events} -> Projector.project_events(stream_id, events)
        {:error, reason} -> Logger.error("Failed to record tool call start: #{inspect(reason)}")
      end
    end)

    auto_confirm = Keyword.get(opts, :auto_confirm, false)

    if auto_confirm do
      # Execute each tool call via MCP client
      tool_servers = Keyword.get(opts, :tool_servers, %{})

      tool_results =
        Enum.map(parsed_tool_calls, fn tc ->
          server = Map.get(tool_servers, tc.name)
          execute_and_record_tool_call(stream_id, message_id, server, tc, opts)
        end)

      # Complete this stream with tool_use stop_reason
      complete_stream_with_stop_reason(
        stream_id,
        message_id,
        full_content,
        "tool_use",
        latency_ms
      )

      # Build messages for the next round
      # Assistant message with text + toolUse blocks
      assistant_content =
        build_assistant_content(full_content, parsed_tool_calls)

      # User message with tool results
      tool_result_content =
        Enum.map(Enum.zip(parsed_tool_calls, tool_results), fn {tc, result} ->
          %{
            "toolResult" => %{
              "toolUseId" => tc.tool_use_id,
              "content" => [%{"text" => format_tool_output(result)}],
              "status" => if(match?({:ok, _}, result), do: "success", else: "error")
            }
          }
        end)

      next_messages =
        messages ++
          [
            %{"role" => "assistant", "content" => assistant_content},
            %{"role" => "user", "content" => tool_result_content}
          ]

      # Start a new stream round (increment tool_round)
      next_opts = Keyword.put(opts, :tool_round, Keyword.get(opts, :tool_round, 0) + 1)
      handle_stream(stream_id, next_messages, next_opts)
    else
      # Manual confirm — wait for approval via PubSub
      tool_servers = Keyword.get(opts, :tool_servers, %{})
      approval_topic = "tool_approval:#{stream_id}"
      Phoenix.PubSub.subscribe(Liteskill.PubSub, approval_topic)

      pending_ids = MapSet.new(parsed_tool_calls, & &1.tool_use_id)
      timeout_ms = Keyword.get(opts, :tool_approval_timeout_ms, @tool_approval_timeout_ms)
      decisions = await_tool_decisions(pending_ids, %{}, timeout_ms)

      Phoenix.PubSub.unsubscribe(Liteskill.PubSub, approval_topic)

      # Execute approved, record rejected
      tool_results =
        Enum.map(parsed_tool_calls, fn tc ->
          case Map.get(decisions, tc.tool_use_id, :rejected) do
            :approved ->
              server = Map.get(tool_servers, tc.name)
              execute_and_record_tool_call(stream_id, message_id, server, tc, opts)

            :rejected ->
              record_rejected_tool_call(stream_id, message_id, tc)
          end
        end)

      # Complete this stream with tool_use stop_reason
      complete_stream_with_stop_reason(
        stream_id,
        message_id,
        full_content,
        "tool_use",
        latency_ms
      )

      # Build messages for the next round
      assistant_content = build_assistant_content(full_content, parsed_tool_calls)

      tool_result_content =
        Enum.map(Enum.zip(parsed_tool_calls, tool_results), fn {tc, result} ->
          %{
            "toolResult" => %{
              "toolUseId" => tc.tool_use_id,
              "content" => [%{"text" => format_tool_output(result)}],
              "status" => if(match?({:ok, _}, result), do: "success", else: "error")
            }
          }
        end)

      next_messages =
        messages ++
          [
            %{"role" => "assistant", "content" => assistant_content},
            %{"role" => "user", "content" => tool_result_content}
          ]

      # Start a new stream round (increment tool_round)
      next_opts = Keyword.put(opts, :tool_round, Keyword.get(opts, :tool_round, 0) + 1)
      handle_stream(stream_id, next_messages, next_opts)
    end
  end

  defp execute_and_record_tool_call(stream_id, message_id, server, tc, opts) do
    start_time = System.monotonic_time(:millisecond)
    req_opts = Keyword.take(opts, [:plug])

    result =
      case server do
        %{builtin: module} ->
          context = Keyword.take(opts, [:user_id])
          module.call_tool(tc.name, tc.input, context)

        server when not is_nil(server) ->
          McpClient.call_tool(server, tc.name, tc.input, req_opts)

        nil ->
          {:error, "No server configured for tool #{tc.name}"}
      end

    duration_ms = System.monotonic_time(:millisecond) - start_time

    output =
      case result do
        {:ok, data} -> data
        {:error, err} -> %{"error" => inspect(err)}
      end

    command =
      {:complete_tool_call,
       %{
         message_id: message_id,
         tool_use_id: tc.tool_use_id,
         tool_name: tc.name,
         input: tc.input,
         output: output,
         duration_ms: duration_ms
       }}

    case Loader.execute(ConversationAggregate, stream_id, command) do
      {:ok, _state, events} -> Projector.project_events(stream_id, events)
      {:error, reason} -> Logger.error("Failed to record tool call complete: #{inspect(reason)}")
    end

    result
  end

  defp await_tool_decisions(pending_ids, decisions, timeout_ms) do
    if MapSet.size(pending_ids) == 0 do
      decisions
    else
      receive do
        {:tool_decision, tool_use_id, decision} when decision in [:approved, :rejected] ->
          new_decisions = Map.put(decisions, tool_use_id, decision)
          new_pending = MapSet.delete(pending_ids, tool_use_id)
          await_tool_decisions(new_pending, new_decisions, timeout_ms)
      after
        timeout_ms ->
          Enum.reduce(pending_ids, decisions, fn id, acc ->
            Map.put(acc, id, :rejected)
          end)
      end
    end
  end

  defp record_rejected_tool_call(stream_id, message_id, tc) do
    command =
      {:complete_tool_call,
       %{
         message_id: message_id,
         tool_use_id: tc.tool_use_id,
         tool_name: tc.name,
         input: tc.input,
         output: %{"error" => "Tool call rejected by user"},
         duration_ms: 0
       }}

    case Loader.execute(ConversationAggregate, stream_id, command) do
      {:ok, _state, events} -> Projector.project_events(stream_id, events)
      {:error, reason} -> Logger.error("Failed to record rejected tool call: #{inspect(reason)}")
    end

    {:error, "Tool call rejected by user"}
  end

  defp complete_stream(stream_id, message_id, full_content, latency_ms, _opts) do
    command =
      {:complete_stream,
       %{
         message_id: message_id,
         full_content: full_content,
         stop_reason: "end_turn",
         latency_ms: latency_ms
       }}

    case Loader.execute(ConversationAggregate, stream_id, command) do
      {:ok, _state, events} ->
        Projector.project_events(stream_id, events)
        :ok

      # coveralls-ignore-next-line
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp complete_stream_with_stop_reason(
         stream_id,
         message_id,
         full_content,
         stop_reason,
         latency_ms
       ) do
    command =
      {:complete_stream,
       %{
         message_id: message_id,
         full_content: full_content,
         stop_reason: stop_reason,
         latency_ms: latency_ms
       }}

    case Loader.execute(ConversationAggregate, stream_id, command) do
      {:ok, _state, events} ->
        Projector.project_events(stream_id, events)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fail_stream(stream_id, message_id, error_type, error_message, retry_count) do
    command =
      {:fail_stream,
       %{
         message_id: message_id,
         error_type: error_type,
         error_message: error_message,
         retry_count: retry_count
       }}

    case Loader.execute(ConversationAggregate, stream_id, command) do
      {:ok, _state, events} ->
        Projector.project_events(stream_id, events)
        {:error, {error_type, error_message}}

      # coveralls-ignore-next-line
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cleanup_tool_ref(ref) do
    Process.delete(ref)
    :ok
  end

  defp default_provider do
    Application.get_env(:liteskill, Liteskill.LLM, [])
    |> Keyword.get(:provider, Liteskill.LLM.BedrockClient)
  end

  defp default_model_id do
    Application.get_env(:liteskill, Liteskill.LLM, [])
    |> Keyword.get(:bedrock_model_id, "us.anthropic.claude-3-5-sonnet-20241022-v2:0")
  end
end
