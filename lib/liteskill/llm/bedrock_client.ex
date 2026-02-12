defmodule Liteskill.LLM.BedrockClient do
  @moduledoc """
  Req-based HTTP client for AWS Bedrock Converse API.

  Uses bearer token authentication. Implements the `Liteskill.LLM.Provider`
  behaviour so StreamHandler can work with any provider.
  """

  @behaviour Liteskill.LLM.Provider

  alias Liteskill.LLM.EventStreamParser

  @doc """
  Non-streaming conversation request.
  """
  def converse(model_id, messages, opts \\ []) do
    {req_opts, body_opts} = Keyword.split(opts, [:plug])
    body = build_request_body(messages, body_opts)

    case Req.post(base_req(), [{:url, converse_url(model_id)}, {:json, body}] ++ req_opts) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      # coveralls-ignore-next-line
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Streaming conversation request.

  Calls `callback` with each parsed event `{event_type, payload}`.
  """
  def converse_stream(model_id, messages, callback, opts \\ []) do
    {req_opts, body_opts} = Keyword.split(opts, [:plug])
    body = build_request_body(messages, body_opts)

    buffer_key = {__MODULE__, :stream_buffer, make_ref()}
    Process.put(buffer_key, <<>>)

    into_fun = fn {:data, data}, {req, resp} ->
      buffer = Process.get(buffer_key, <<>>)
      {events, remaining} = EventStreamParser.parse(buffer <> data)
      Process.put(buffer_key, remaining)
      Enum.each(events, callback)
      {:cont, {req, resp}}
    end

    result =
      case Req.post(
             base_req(),
             [
               {:url, converse_stream_url(model_id)},
               {:json, body},
               {:into, into_fun},
               {:receive_timeout, 120_000}
             ] ++
               req_opts
           ) do
        {:ok, %{status: 200}} ->
          :ok

        {:ok, %{status: status, body: body}} ->
          {:error, %{status: status, body: body}}

        # coveralls-ignore-next-line
        {:error, reason} ->
          {:error, reason}
      end

    Process.delete(buffer_key)
    result
  end

  defp build_request_body(messages, opts) do
    body = %{
      "messages" => format_messages(messages),
      "inferenceConfig" => %{
        "maxTokens" => Keyword.get(opts, :max_tokens, 4096),
        "temperature" => Keyword.get(opts, :temperature, 1.0)
      }
    }

    body =
      case Keyword.get(opts, :tools) do
        nil -> body
        [] -> body
        tools -> Map.put(body, "toolConfig", %{"tools" => tools})
      end

    case Keyword.get(opts, :system) do
      nil -> body
      system -> Map.put(body, "system", [%{"text" => system}])
    end
  end

  defp format_messages(messages) do
    Enum.map(messages, fn
      %{role: role, content: content} when is_binary(content) ->
        %{"role" => to_string(role), "content" => [%{"text" => content}]}

      %{"role" => role, "content" => content} when is_binary(content) ->
        %{"role" => role, "content" => [%{"text" => content}]}

      msg ->
        msg
    end)
  end

  defp base_req do
    token = config(:bedrock_bearer_token)

    Req.new(
      headers: [
        {"authorization", "Bearer #{token}"},
        {"content-type", "application/json"}
      ]
    )
  end

  defp converse_url(model_id) do
    region = config(:bedrock_region)
    "https://bedrock-runtime.#{region}.amazonaws.com/model/#{URI.encode(model_id)}/converse"
  end

  defp converse_stream_url(model_id) do
    region = config(:bedrock_region)

    "https://bedrock-runtime.#{region}.amazonaws.com/model/#{URI.encode(model_id)}/converse-stream"
  end

  defp config(key) do
    Application.get_env(:liteskill, Liteskill.LLM, [])
    |> Keyword.get(key)
  end
end
