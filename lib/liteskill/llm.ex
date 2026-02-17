defmodule Liteskill.LLM do
  use Boundary,
    top_level?: true,
    deps: [
      Liteskill.Chat,
      Liteskill.Aggregate,
      Liteskill.EventStore,
      Liteskill.Usage,
      Liteskill.LlmModels,
      Liteskill.McpServers
    ],
    exports: [StreamHandler, ToolUtils, RagContext]

  @moduledoc """
  Public API for LLM interactions.

  Uses ReqLLM for transport. `complete/2` is used for non-streaming calls
  (e.g. conversation title generation). Streaming is handled by
  `StreamHandler` directly.

  Models are configured in the database via admin UI — there are no
  hardcoded model IDs or env-var fallbacks for model selection.
  """

  alias Liteskill.LLM.StreamHandler
  alias Liteskill.Usage

  @doc """
  Sends a non-streaming completion request.

  Requires either `:llm_model` (a `%LlmModel{}` struct) or `:model_id` +
  `:provider_options` to be passed in opts.

  ## Options
    - `:llm_model` - A `%LlmModel{}` struct with full provider config
    - `:model_id` - Model ID string (requires `:provider_options` too)
    - `:max_tokens` - Maximum tokens to generate
    - `:temperature` - Sampling temperature
    - `:system` - System prompt
    - `:generate_fn` - Override the generation function (for testing)
  """
  def complete(messages, opts \\ []) do
    llm_model = Keyword.get(opts, :llm_model)

    {model, req_opts} =
      if llm_model do
        {model_spec, model_opts} = Liteskill.LlmModels.build_provider_options(llm_model)
        {model_spec, model_opts}
      else
        model_id =
          Keyword.get(opts, :model_id) ||
            raise "No model specified: pass :llm_model or :model_id option"

        provider_opts = Keyword.get(opts, :provider_options, [])
        {StreamHandler.to_req_llm_model(model_id), [provider_options: provider_opts]}
      end

    context = StreamHandler.to_req_llm_context(messages)

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

    generate_fn = Keyword.get(opts, :generate_fn, &default_generate/3)

    case generate_fn.(model, context, req_opts) do
      {:ok, response} ->
        text = ReqLLM.Response.text(response) || ""
        maybe_record_complete_usage(response, model, opts)

        {:ok,
         %{"output" => %{"message" => %{"role" => "assistant", "content" => [%{"text" => text}]}}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # coveralls-ignore-start
  defp default_generate(model, context, opts) do
    ReqLLM.generate_text(model, context, opts)
  end

  # coveralls-ignore-stop

  defp maybe_record_complete_usage(response, model, opts) do
    usage = ReqLLM.Response.usage(response) || %{}
    model_id = if is_map(model), do: model[:id], else: to_string(model)

    Usage.record_from_response(usage,
      user_id: Keyword.get(opts, :user_id),
      llm_model: Keyword.get(opts, :llm_model),
      model_id: model_id || "unknown",
      conversation_id: Keyword.get(opts, :conversation_id),
      call_type: "complete"
    )
  end

  @doc """
  Returns active LLM models available to the given user (DB-only).
  """
  def available_models(user_id) do
    Liteskill.LlmModels.list_active_models(user_id, model_type: "inference")
  end
end
