defmodule Liteskill.Agents.Actions.LlmGenerate do
  @moduledoc """
  Jido Action that calls the LLM via ReqLLM with a tool-calling loop.

  Reads configuration from agent state (system_prompt, backstory, opinions,
  role, strategy, llm_model, tools, tool_servers) and makes a non-streaming
  LLM call. If the LLM returns tool calls, executes them and loops.

  ## Performance optimizations

  - **Prompt caching**: Enables Anthropic prompt caching on Bedrock models
  - **Receive timeout**: Per-call timeout prevents indefinitely stuck calls
  - **Context pruning**: Sliding window truncates old tool results after N rounds
  - **Iteration limits**: Per-agent `max_iterations` via `config["max_iterations"]`
  - **Progress broadcasting**: Logs each LLM round for real-time UI updates
  """

  use Jido.Action,
    name: "llm_generate",
    description: "Calls the LLM with prompt, system prompt, and tools",
    schema: []

  alias Liteskill.LLM.{StreamHandler, ToolUtils}

  require Logger

  @max_retries 3
  @default_backoff_ms 1000
  @default_receive_timeout 120_000
  @default_max_iterations 25
  @default_keep_rounds 4

  def run(_params, context) do
    state = context.state

    if state[:llm_model] do
      {system_prompt, llm_context} =
        case state[:resume_messages] do
          # coveralls-ignore-start
          messages when is_list(messages) and messages != [] ->
            Logger.info(
              "LlmGenerate: resuming #{state[:agent_name]} from #{length(messages)} saved messages"
            )

            deserialize_context(messages)

          # coveralls-ignore-stop

          _ ->
            system_prompt = build_system_prompt(state)
            user_message = build_user_message(state)
            {system_prompt, ReqLLM.Context.new([ReqLLM.Context.user(user_message)])}
        end

      case llm_call_loop(state[:llm_model], system_prompt, llm_context, state, 0) do
        {:ok, response_text, final_context} ->
          analysis = build_analysis_header(state)
          messages = serialize_context(system_prompt, final_context)
          {:ok, %{analysis: analysis, output: response_text, messages: messages}}

        {:error, reason, partial_context} ->
          messages = serialize_context(system_prompt, partial_context)

          {:error,
           %{
             reason: "LLM call failed for agent '#{state[:agent_name]}': #{inspect(reason)}",
             messages: messages
           }}
      end
    else
      {:error, "No LLM model configured for agent '#{state[:agent_name]}'"}
    end
  end

  # -- System prompt construction --

  @doc false
  def build_system_prompt(state) do
    parts = []

    parts =
      if state[:system_prompt] && state[:system_prompt] != "" do
        parts ++ [state[:system_prompt]]
      else
        parts
      end

    parts = parts ++ ["You are acting as a #{state[:role]} in a multi-agent pipeline."]

    parts =
      if state[:backstory] && state[:backstory] != "" do
        parts ++ ["Background: #{state[:backstory]}"]
      else
        parts
      end

    parts =
      if is_map(state[:opinions]) && map_size(state[:opinions]) > 0 do
        opinion_lines =
          Enum.map_join(state[:opinions], "\n", fn {k, v} -> "- #{k}: #{v}" end)

        parts ++ ["Your perspectives:\n#{opinion_lines}"]
      else
        parts
      end

    strategy_hint =
      case state[:strategy] do
        "react" ->
          "Use a Reason-Act approach: think step by step, observe, then act."

        "chain_of_thought" ->
          "Use chain-of-thought reasoning: work through the problem step by step."

        "tree_of_thoughts" ->
          "Explore multiple approaches before selecting the best one."

        "direct" ->
          "Provide a direct, focused response."

        other ->
          "Use the #{other} approach."
      end

    parts = parts ++ [strategy_hint]

    # Batch optimization hint when tools are available
    parts =
      if (state[:tools] || []) != [] do
        parts ++
          [
            "When using tools, prefer batching multiple operations into a single tool call " <>
              "where the tool supports batch operations (e.g. multiple actions in wiki__write " <>
              "or reports__modify_sections). This reduces round-trips and improves efficiency."
          ]
      else
        parts
      end

    parts =
      if state[:report_id] do
        parts ++
          [
            "IMPORTANT: End your response with a '## Handoff Summary' section: " <>
              "3-5 bullet points (max 500 chars) summarizing what you did, " <>
              "key findings, and what the next agent needs to know.",
            "Prior stage full outputs are in the pipeline report. " <>
              "Use the reports__get tool with report_id '#{state[:report_id]}' " <>
              "to read details if needed.",
            "IMPORTANT: A pipeline report already exists with id '#{state[:report_id]}'. " <>
              "Do NOT create a new report with reports__create. Instead, use " <>
              "reports__modify_sections with this report_id to add your sections directly."
          ]
      else
        parts
      end

    Enum.join(parts, "\n\n")
  end

  defp build_user_message(state) do
    base = state[:prompt] || ""

    if state[:prior_context] && state[:prior_context] != "" do
      "Previous stage handoffs:\n#{state[:prior_context]}\n\nTask: #{base}"
    else
      base
    end
  end

  defp build_analysis_header(state) do
    "**Agent:** #{state[:agent_name]}\n" <>
      "**Role:** #{state[:role]}\n" <>
      "**Strategy:** #{state[:strategy]}\n"
  end

  # -- LLM call with tool loop --

  defp llm_call_loop(llm_model, system_prompt, llm_context, state, round) do
    max_iter = get_in(state, [:config, "max_iterations"]) || @default_max_iterations

    cond do
      round >= max_iter ->
        Logger.warning("LlmGenerate: #{state[:agent_name]} hit max iterations (#{max_iter})")

        last_text = extract_last_assistant_text(llm_context)
        {:ok, last_text <> "\n\n[Max iterations (#{max_iter}) reached]", llm_context}

      cost_limit_exceeded?(state) ->
        cost_limit = state[:cost_limit]

        Logger.warning("LlmGenerate: #{state[:agent_name]} hit cost limit ($#{cost_limit})")

        last_text = extract_last_assistant_text(llm_context)

        {:ok, last_text <> "\n\n[Cost limit of $#{cost_limit} reached]", llm_context}

      true ->
        do_llm_call(llm_model, system_prompt, llm_context, state, round)
    end
  end

  defp cost_limit_exceeded?(state) do
    cost_limit = state[:cost_limit]
    run_id = state[:run_id]

    if cost_limit && run_id do
      case Liteskill.Usage.check_cost_limit(:run, run_id, cost_limit) do
        :ok -> false
        {:error, :cost_limit_exceeded, _} -> true
      end
    else
      false
    end
  end

  defp do_llm_call(llm_model, system_prompt, llm_context, state, round) do
    {model_spec, req_opts} =
      Liteskill.LlmModels.build_provider_options(llm_model, enable_caching: true)

    req_opts = Keyword.merge(req_opts, Application.get_env(:liteskill, :test_req_opts, []))

    # Per-call receive timeout to prevent indefinitely stuck calls
    req_opts = Keyword.put_new(req_opts, :receive_timeout, @default_receive_timeout)

    req_opts = Keyword.put(req_opts, :system_prompt, system_prompt)

    tools = state[:tools] || []

    req_opts =
      if tools != [] do
        reqllm_tools = Enum.map(tools, &ToolUtils.convert_tool/1)
        Keyword.put(req_opts, :tools, reqllm_tools)
      else
        req_opts
      end

    # Enable Anthropic prompt caching when the model supports it (use_converse: false).
    # Bedrock limits cache_control to 4 blocks. ReqLLM adds cache_control to
    # system (1 block) + every tool (N blocks), so we can only enable it when
    # total blocks ≤ 4 (i.e. ≤ 3 tools).
    req_opts = maybe_enable_prompt_cache(req_opts, length(tools))

    start_time = System.monotonic_time(:millisecond)

    case generate_with_retry(model_spec, llm_context, req_opts, state) do
      {:ok, response} ->
        latency_ms = System.monotonic_time(:millisecond) - start_time
        record_usage(response, llm_model, state, latency_ms, round)

        text = ReqLLM.Response.text(response) || ""
        raw_tool_calls = ReqLLM.Response.tool_calls(response) || []

        broadcast_progress(state, round, raw_tool_calls != [])

        if raw_tool_calls == [] do
          {:ok, text, response.context}
        else
          tool_calls = Enum.map(raw_tool_calls, &normalize_tool_call/1)
          tool_results = execute_tool_calls(tool_calls, state)

          # Build next context: response.context already has assistant message,
          # append tool results using ReqLLM's format
          next_context = append_tool_results(response.context, tool_calls, tool_results)
          next_context = maybe_prune_context(next_context, round)
          llm_call_loop(llm_model, system_prompt, next_context, state, round + 1)
        end

      {:error, reason} ->
        {:error, reason, llm_context}
    end
  end

  defp generate_with_retry(model_spec, llm_context, req_opts, state, attempt \\ 0) do
    case ReqLLM.generate_text(model_spec, llm_context, req_opts) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        if attempt < @max_retries && StreamHandler.retryable_error?(reason) do
          backoff_ms = Keyword.get(state[:retry_opts] || [], :backoff_ms, @default_backoff_ms)
          jitter = :rand.uniform()
          backoff = trunc(backoff_ms * Integer.pow(2, attempt) * (1 + jitter))

          Logger.warning(
            "LlmGenerate: retryable error for #{state[:agent_name]}, " <>
              "retrying in #{backoff}ms (attempt #{attempt + 1}/#{@max_retries})"
          )

          Process.sleep(backoff)
          generate_with_retry(model_spec, llm_context, req_opts, state, attempt + 1)
        else
          {:error, reason}
        end
    end
  end

  # -- Progress broadcasting --

  defp broadcast_progress(state, round, has_tool_calls) do
    log_fn = state[:log_fn]

    if state[:run_id] && log_fn do
      status = if has_tool_calls, do: "tool_calling", else: "generating"

      log_fn.(
        state[:run_id],
        "debug",
        "llm_round",
        "#{state[:agent_name]} round #{round + 1} (#{status})",
        %{
          "agent" => state[:agent_name],
          "round" => round + 1,
          "status" => status
        }
      )
    end
  end

  # -- Context pruning (sliding window) --

  @doc false
  def maybe_prune_context(context, round) do
    if round < @default_keep_rounds do
      context
    else
      prune_old_tool_results(context, @default_keep_rounds)
    end
  end

  @doc false
  def prune_old_tool_results(context, keep_rounds) do
    messages = context.messages

    # Count total tool-calling rounds (assistant messages with tool_calls)
    total_rounds =
      Enum.count(messages, fn msg ->
        msg.role == :assistant && msg.tool_calls != nil && msg.tool_calls != []
      end)

    cutoff_round = total_rounds - keep_rounds

    if cutoff_round <= 0 do
      context
    else
      # Walk messages, tracking which round each tool result belongs to
      {pruned, _current_round} =
        Enum.map_reduce(messages, 0, fn msg, current_round ->
          cond do
            # Assistant message with tool calls starts a new round
            msg.role == :assistant && msg.tool_calls != nil && msg.tool_calls != [] ->
              {msg, current_round + 1}

            # Tool result messages belong to the current round
            msg.role == :tool && current_round > 0 && current_round <= cutoff_round ->
              truncated_content = [
                %ReqLLM.Message.ContentPart{
                  type: :text,
                  text: "[Result from earlier round — truncated to save context]"
                }
              ]

              {%{msg | content: truncated_content}, current_round}

            true ->
              {msg, current_round}
          end
        end)

      %{context | messages: pruned}
    end
  end

  # -- Max iterations helper --

  defp extract_last_assistant_text(context) do
    context.messages
    |> Enum.reverse()
    |> Enum.find(fn msg -> msg.role == :assistant end)
    |> case do
      # coveralls-ignore-next-line
      nil ->
        ""

      msg ->
        msg.content
        |> Enum.filter(fn part -> part.type == :text end)
        |> Enum.map_join("", fn part -> part.text || "" end)
    end
  end

  # -- Tool call normalization --

  defp normalize_tool_call(tc) do
    input =
      case Jason.decode(tc.function.arguments) do
        {:ok, decoded} -> decoded
        # coveralls-ignore-next-line
        {:error, _} -> %{"_raw" => tc.function.arguments}
      end

    %{
      tool_use_id: tc.id,
      name: tc.function.name,
      input: input
    }
  end

  # -- Tool execution --

  defp execute_tool_calls(tool_calls, state) do
    tool_servers = state[:tool_servers] || %{}
    user_id = state[:user_id]

    Enum.map(tool_calls, fn tc ->
      server = Map.get(tool_servers, tc.name)
      ToolUtils.execute_tool(server, tc.name, tc.input, user_id: user_id)
    end)
  end

  # -- Context building for tool results --

  defp append_tool_results(llm_context, tool_calls, tool_results) do
    tool_result_messages =
      Enum.zip(tool_calls, tool_results)
      |> Enum.map(fn {tc, result} ->
        ReqLLM.Context.tool_result(tc.tool_use_id, tc.name, ToolUtils.format_tool_output(result))
      end)

    Enum.reduce(tool_result_messages, llm_context, &ReqLLM.Context.append(&2, &1))
  end

  # -- Context serialization for logging --

  defp serialize_context(system_prompt, context) do
    system_msg = %{"role" => "system", "content" => system_prompt}
    context_msgs = context.messages |> Jason.encode!() |> Jason.decode!()
    context_msgs = Enum.reject(context_msgs, &(&1["role"] == "system"))
    [system_msg | context_msgs]
  end

  @doc false
  def deserialize_context(messages) do
    {system_msgs, context_msgs} = Enum.split_with(messages, &(&1["role"] == "system"))
    system_prompt = Enum.map_join(system_msgs, "\n\n", &extract_text(&1["content"]))

    reqllm_messages =
      Enum.map(context_msgs, fn msg ->
        text = extract_text(msg["content"])

        case msg["role"] do
          "user" ->
            ReqLLM.Context.user(text)

          "assistant" ->
            case msg["tool_calls"] do
              tcs when is_list(tcs) and tcs != [] ->
                tool_calls = Enum.map(tcs, &deserialize_tool_call/1)
                ReqLLM.Context.assistant(text, tool_calls: tool_calls)

              _ ->
                ReqLLM.Context.assistant(text)
            end

          "tool" ->
            ReqLLM.Context.tool_result(msg["tool_call_id"], msg["name"], text)
        end
      end)

    {system_prompt, ReqLLM.Context.new(reqllm_messages)}
  end

  defp extract_text(content) when is_list(content) do
    content
    |> Enum.filter(fn c -> is_map(c) && c["type"] == "text" end)
    |> Enum.map_join("", fn c -> c["text"] || "" end)
  end

  defp extract_text(content) when is_binary(content), do: content
  # coveralls-ignore-next-line
  defp extract_text(_), do: ""

  defp deserialize_tool_call(tc) do
    args =
      case tc["function"]["arguments"] do
        a when is_binary(a) ->
          case Jason.decode(a) do
            {:ok, decoded} ->
              decoded

            # coveralls-ignore-start
            {:error, err} ->
              Logger.warning(
                "Failed to decode tool call arguments during deserialization: #{inspect(err)}, raw: #{inspect(a)}"
              )

              %{}
              # coveralls-ignore-stop
          end

        # coveralls-ignore-start
        a when is_map(a) ->
          a

        _ ->
          %{}
          # coveralls-ignore-stop
      end

    %{id: tc["id"], name: tc["function"]["name"], arguments: args}
  end

  # -- Prompt caching guard --

  @max_cached_tool_blocks 3

  @doc false
  def maybe_enable_prompt_cache(req_opts, tool_count) do
    provider_opts = Keyword.get(req_opts, :provider_options, [])
    use_converse = Keyword.get(provider_opts, :use_converse)

    if use_converse == false && tool_count <= @max_cached_tool_blocks do
      provider_opts =
        provider_opts
        |> Keyword.put(:anthropic_prompt_cache, true)
        |> Keyword.put(:anthropic_cache_messages, -1)

      Keyword.put(req_opts, :provider_options, provider_opts)
    else
      req_opts
    end
  end

  # -- Usage recording --

  defp record_usage(response, llm_model, state, latency_ms, tool_round) do
    usage = ReqLLM.Response.usage(response) || %{}

    Liteskill.Usage.record_from_response(usage,
      user_id: state[:user_id],
      llm_model: llm_model,
      run_id: state[:run_id],
      latency_ms: latency_ms,
      call_type: "complete",
      tool_round: tool_round
    )
  end
end
