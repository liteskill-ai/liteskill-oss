defmodule Liteskill.LLM.StreamHandler do
  @moduledoc """
  Orchestrates streaming LLM calls with event store integration.

  Uses ReqLLM for LLM transport. Appends AssistantStreamStarted, fires
  AssistantChunkReceived per text chunk, then AssistantStreamCompleted or
  AssistantStreamFailed. Includes retry with exponential backoff for 429/503.

  Supports tool calling: when the LLM returns tool_use, records ToolCallStarted
  events. In auto-confirm mode, executes tools via MCP client and continues the
  conversation loop. Otherwise, completes with stop_reason="tool_use" for manual
  confirmation by the UI.
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

    * `:model_id` - Model ID
    * `:system` - System prompt
    * `:tools` - List of toolConfig tool specs
    * `:tool_servers` - Map of `"tool_name" => server` for MCP execution
    * `:auto_confirm` - Boolean, auto-execute tool calls (default false)
    * `:backoff_ms` - Base backoff for retries
    * `:tool_approval_timeout_ms` - Timeout for manual tool approval (default 300_000)
    * `:max_tool_rounds` - Max consecutive tool-calling rounds (default 10)
    * `:stream_fn` - Override the LLM streaming function (for testing)
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
    llm_model = Keyword.get(opts, :llm_model)

    model_id =
      cond do
        llm_model -> llm_model.model_id
        Keyword.has_key?(opts, :model_id) -> Keyword.get(opts, :model_id)
        true -> raise "No model specified: pass :llm_model or :model_id option"
      end

    message_id = Ecto.UUID.generate()
    rag_sources = Keyword.get(opts, :rag_sources)

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

    on_text_chunk = fn text_chunk ->
      idx = :counters.get(chunk_index, 1)
      :counters.add(chunk_index, 1, 1)

      command =
        {:receive_chunk,
         %{
           message_id: message_id,
           chunk_index: idx,
           content_block_index: 0,
           delta_type: "text_delta",
           delta_text: text_chunk
         }}

      case Loader.execute(ConversationAggregate, stream_id, command) do
        {:ok, _state, events} -> Projector.project_events_async(stream_id, events)
        # coveralls-ignore-next-line
        {:error, reason} -> Logger.error("Failed to record chunk: #{inspect(reason)}")
      end
    end

    stream_fn = Keyword.get(opts, :stream_fn, &default_stream/4)
    call_opts = build_call_opts(opts)

    case stream_fn.(model_id, messages, on_text_chunk, call_opts) do
      {:ok, full_content, tool_calls} ->
        latency_ms = System.monotonic_time(:millisecond) - start_time

        if tool_calls != [] do
          handle_tool_calls(
            stream_id,
            message_id,
            messages,
            full_content,
            tool_calls,
            latency_ms,
            opts
          )
        else
          complete_stream(stream_id, message_id, full_content, latency_ms)
        end

      {:error, %{status: status}} when status in [429, 503] ->
        base_backoff = Keyword.get(opts, :backoff_ms, @default_backoff_ms)
        jitter = :rand.uniform()
        backoff = trunc(base_backoff * Integer.pow(2, retry_count) * (1 + jitter))

        Logger.warning("Bedrock #{status}, retrying in #{backoff}ms (attempt #{retry_count + 1})")

        Process.sleep(backoff)
        do_stream_with_retry(stream_id, message_id, model_id, messages, opts, retry_count + 1)

      {:error, reason} ->
        error_message = extract_error_message(reason)
        Logger.warning("StreamHandler: LLM request failed for #{stream_id}: #{error_message}")
        fail_stream(stream_id, message_id, "request_error", error_message, retry_count)
    end
  end

  # -- LLM call (ReqLLM) --

  # coveralls-ignore-start
  defp default_stream(model_id, messages, on_text_chunk, opts) do
    {llm_model, opts} = Keyword.pop(opts, :llm_model)
    model = if llm_model, do: to_req_llm_model(llm_model), else: to_req_llm_model(model_id)
    context = to_req_llm_context(messages)

    case ReqLLM.stream_text(model, context, opts) do
      {:ok, stream_response} ->
        case ReqLLM.StreamResponse.process_stream(stream_response,
               on_result: fn chunk -> on_text_chunk.(chunk) end
             ) do
          {:ok, response} ->
            text = ReqLLM.Response.text(response) || ""
            raw_tool_calls = ReqLLM.Response.tool_calls(response) || []
            tool_calls = Enum.map(raw_tool_calls, &normalize_tool_call/1)
            {:ok, text, tool_calls}

          {:error, reason} ->
            {:error, normalize_error(reason)}
        end

      {:error, reason} ->
        {:error, normalize_error(reason)}
    end
  end

  defp normalize_tool_call(tc) do
    %{
      tool_use_id: tc.id,
      name: tc.function.name,
      input: Jason.decode!(tc.function.arguments)
    }
  end

  # coveralls-ignore-stop

  # -- Message / Context translation --

  @doc false
  def to_req_llm_model(%Liteskill.LlmModels.LlmModel{provider: %{provider_type: pt}} = m) do
    %{id: m.model_id, provider: String.to_existing_atom(pt)}
  end

  def to_req_llm_model(model_id) when is_binary(model_id) do
    %{id: model_id, provider: :amazon_bedrock}
  end

  @doc false
  def to_req_llm_context(messages) do
    messages
    |> Enum.flat_map(&convert_message/1)
    |> ReqLLM.Context.new()
  end

  defp convert_message(%{role: role, content: content}) when is_binary(content) do
    [build_simple_message(to_string(role), content)]
  end

  defp convert_message(%{"role" => "user", "content" => blocks}) when is_list(blocks) do
    tool_results = Enum.filter(blocks, &match?(%{"toolResult" => _}, &1))

    if tool_results != [] do
      Enum.map(tool_results, fn %{"toolResult" => tr} ->
        text = extract_tool_result_text(tr)
        ReqLLM.Context.tool_result(tr["toolUseId"], text)
      end)
    else
      text = extract_text_from_blocks(blocks)
      [ReqLLM.Context.user(text)]
    end
  end

  defp convert_message(%{"role" => "assistant", "content" => blocks}) when is_list(blocks) do
    text = extract_text_from_blocks(blocks)
    tool_use_blocks = Enum.filter(blocks, &match?(%{"toolUse" => _}, &1))

    if tool_use_blocks != [] do
      tool_calls =
        Enum.map(tool_use_blocks, fn %{"toolUse" => tu} ->
          %{id: tu["toolUseId"], name: tu["name"], arguments: tu["input"] || %{}}
        end)

      [ReqLLM.Context.assistant(text, tool_calls: tool_calls)]
    else
      [ReqLLM.Context.assistant(text)]
    end
  end

  defp convert_message(%{"role" => role, "content" => content}) when is_binary(content) do
    [build_simple_message(role, content)]
  end

  defp build_simple_message("user", text), do: ReqLLM.Context.user(text)
  defp build_simple_message("assistant", text), do: ReqLLM.Context.assistant(text)

  defp extract_text_from_blocks(blocks) do
    blocks
    |> Enum.filter(&match?(%{"text" => _}, &1))
    |> Enum.map_join("", & &1["text"])
  end

  defp extract_tool_result_text(%{"content" => [%{"text" => text} | _]}), do: text

  defp extract_tool_result_text(%{"content" => content}) when is_list(content) do
    Enum.map_join(content, "\n", &Jason.encode!/1)
  end

  defp extract_tool_result_text(_), do: ""

  # -- Options translation --

  defp build_call_opts(opts) do
    llm_model = Keyword.get(opts, :llm_model)

    req_opts =
      case llm_model do
        nil ->
          [provider_options: bedrock_provider_options()]

        llm_model ->
          {_model_spec, model_opts} = Liteskill.LlmModels.build_provider_options(llm_model)
          Keyword.put(model_opts, :llm_model, llm_model)
      end

    req_opts =
      case Keyword.get(opts, :system) do
        nil -> req_opts
        system -> Keyword.put(req_opts, :system_prompt, system)
      end

    req_opts =
      case Keyword.get(opts, :temperature) do
        nil -> req_opts
        temp -> Keyword.put(req_opts, :temperature, temp)
      end

    req_opts =
      case Keyword.get(opts, :max_tokens) do
        nil -> req_opts
        max -> Keyword.put(req_opts, :max_tokens, max)
      end

    case Keyword.get(opts, :tools) do
      nil -> req_opts
      [] -> req_opts
      tools -> Keyword.put(req_opts, :tools, Enum.map(tools, &convert_tool/1))
    end
  end

  defp bedrock_provider_options do
    config = Application.get_env(:liteskill, Liteskill.LLM, [])

    opts = [region: Keyword.get(config, :bedrock_region, "us-east-1"), use_converse: true]

    case Keyword.get(config, :bedrock_bearer_token) do
      nil -> opts
      token -> Keyword.put(opts, :api_key, token)
    end
  end

  defp convert_tool(%{"toolSpec" => spec}) do
    ReqLLM.tool(
      name: spec["name"],
      description: spec["description"] || "",
      parameter_schema: get_in(spec, ["inputSchema", "json"]) || %{},
      # coveralls-ignore-next-line
      callback: fn _args -> {:ok, nil} end
    )
  end

  @doc false
  def extract_error_message(%{status: status, response_body: rb})
      when is_integer(status) and is_map(rb) do
    body_text = Map.get(rb, "message", Map.get(rb, "Message", Jason.encode!(rb)))
    body_text = truncate_error(body_text, 500)
    if body_text != "", do: "HTTP #{status}: #{body_text}", else: "HTTP #{status}"
  end

  def extract_error_message(%{status: status, body: body}) when is_integer(status) do
    body_text =
      case body do
        b when is_binary(b) -> b
        b when is_map(b) -> Map.get(b, "message", Map.get(b, "Message", Jason.encode!(b)))
        b when is_list(b) -> Jason.encode!(b)
        _ -> ""
      end

    body_text = truncate_error(body_text, 500)
    if body_text != "", do: "HTTP #{status}: #{body_text}", else: "HTTP #{status}"
  end

  def extract_error_message(%{status: status}) when is_integer(status), do: "HTTP #{status}"

  def extract_error_message(%Mint.TransportError{reason: reason}),
    do: "connection error: #{reason}"

  def extract_error_message(%{reason: reason}) when is_binary(reason), do: reason

  def extract_error_message(reason) when is_binary(reason), do: reason

  def extract_error_message(reason) when is_atom(reason), do: Atom.to_string(reason)

  def extract_error_message(_reason), do: "LLM request failed"

  defp truncate_error(text, max) when byte_size(text) > max do
    String.slice(text, 0, max) <> "..."
  end

  defp truncate_error(text, _max), do: text

  # coveralls-ignore-start
  # normalize_error is only called from default_stream
  defp normalize_error(%{status: _} = error) when not is_struct(error), do: error

  defp normalize_error(error) when is_struct(error) do
    cond do
      Map.has_key?(error, :status) and is_integer(Map.get(error, :status)) ->
        body =
          cond do
            # ReqLLM.Error.API.Request has response_body with the actual error
            Map.has_key?(error, :response_body) and is_map(Map.get(error, :response_body)) ->
              Map.get(error, :response_body)

            Map.has_key?(error, :body) ->
              Map.get(error, :body)

            Map.has_key?(error, :reason) ->
              Map.get(error, :reason)

            true ->
              inspect(error)
          end

        %{status: Map.get(error, :status), body: body}

      true ->
        error
    end
  end

  defp normalize_error(error), do: error
  # coveralls-ignore-stop

  # -- Tool call validation --

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
  def format_tool_output({:error, _err}), do: "Error: tool execution failed"

  # -- Tool call handling --

  defp handle_tool_calls(
         stream_id,
         message_id,
         messages,
         full_content,
         tool_calls,
         latency_ms,
         opts
       ) do
    tools = Keyword.get(opts, :tools, [])
    validated = validate_tool_calls(tool_calls, tools)

    if validated == [] do
      complete_stream(stream_id, message_id, full_content, latency_ms)
    else
      do_handle_tool_calls(
        stream_id,
        message_id,
        messages,
        full_content,
        validated,
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
    auto_confirm = Keyword.get(opts, :auto_confirm, false)

    approval_topic = "tool_approval:#{stream_id}"
    if !auto_confirm, do: Phoenix.PubSub.subscribe(Liteskill.PubSub, approval_topic)

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
        # coveralls-ignore-next-line
        {:error, reason} -> Logger.error("Failed to record tool call start: #{inspect(reason)}")
      end
    end)

    tool_results =
      execute_or_await_tool_calls(
        stream_id,
        message_id,
        parsed_tool_calls,
        auto_confirm,
        approval_topic,
        opts
      )

    if !auto_confirm, do: Phoenix.PubSub.unsubscribe(Liteskill.PubSub, approval_topic)

    complete_stream_with_stop_reason(stream_id, message_id, full_content, "tool_use", latency_ms)

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

    next_opts = Keyword.put(opts, :tool_round, Keyword.get(opts, :tool_round, 0) + 1)
    handle_stream(stream_id, next_messages, next_opts)
  end

  defp execute_or_await_tool_calls(
         stream_id,
         message_id,
         parsed_tool_calls,
         true = _auto_confirm,
         _topic,
         opts
       ) do
    tool_servers = Keyword.get(opts, :tool_servers, %{})

    Enum.map(parsed_tool_calls, fn tc ->
      server = Map.get(tool_servers, tc.name)
      execute_and_record_tool_call(stream_id, message_id, server, tc, opts)
    end)
  end

  defp execute_or_await_tool_calls(
         stream_id,
         message_id,
         parsed_tool_calls,
         false = _auto_confirm,
         _topic,
         opts
       ) do
    tool_servers = Keyword.get(opts, :tool_servers, %{})
    pending_ids = MapSet.new(parsed_tool_calls, & &1.tool_use_id)
    timeout_ms = Keyword.get(opts, :tool_approval_timeout_ms, @tool_approval_timeout_ms)
    decisions = await_tool_decisions(pending_ids, %{}, timeout_ms)

    Enum.map(parsed_tool_calls, fn tc ->
      case Map.get(decisions, tc.tool_use_id, :rejected) do
        :approved ->
          server = Map.get(tool_servers, tc.name)
          execute_and_record_tool_call(stream_id, message_id, server, tc, opts)

        :rejected ->
          record_rejected_tool_call(stream_id, message_id, tc)
      end
    end)
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
          # coveralls-ignore-next-line
          McpClient.call_tool(server, tc.name, tc.input, req_opts)

        nil ->
          {:error, "No server configured for tool #{tc.name}"}
      end

    duration_ms = System.monotonic_time(:millisecond) - start_time

    output =
      case result do
        {:ok, data} -> data
        {:error, _err} -> %{"error" => "tool execution failed"}
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
      # coveralls-ignore-next-line
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
      # coveralls-ignore-next-line
      {:error, reason} -> Logger.error("Failed to record rejected tool call: #{inspect(reason)}")
    end

    {:error, "Tool call rejected by user"}
  end

  # -- Stream completion / failure --

  defp complete_stream(stream_id, message_id, full_content, latency_ms) do
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

      # coveralls-ignore-next-line
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
end
