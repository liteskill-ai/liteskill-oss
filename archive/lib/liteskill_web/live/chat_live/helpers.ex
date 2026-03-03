defmodule LiteskillWeb.ChatLive.Helpers do
  @moduledoc false

  @doc """
  Estimates how many tokens a given cost would buy for the specified model.
  Returns nil if the model is not found or has no input rate.
  """
  def estimate_tokens(cost_decimal, model_id, models) do
    zero = Decimal.new(0)

    case Enum.find(models, &(&1.id == model_id)) do
      %{input_cost_per_million: rate} when not is_nil(rate) ->
        if Decimal.compare(rate, zero) != :eq do
          cost_decimal
          |> Decimal.div(rate)
          |> Decimal.mult(1_000_000)
          |> Decimal.round(0)
          |> Decimal.to_integer()
        end

      _ ->
        nil
    end
  end

  @doc """
  Estimates the cost for a given number of tokens at the model's input rate.
  Returns nil if the model is not found or has no input rate.
  """
  def estimate_cost(tokens, model_id, models) do
    case Enum.find(models, &(&1.id == model_id)) do
      %{input_cost_per_million: rate} when not is_nil(rate) ->
        tokens
        |> Decimal.new()
        |> Decimal.mult(rate)
        |> Decimal.div(1_000_000)

      _ ->
        nil
    end
  end

  @doc """
  Truncates message content to create a conversation title.
  Takes the first line, max 50 chars (with "..." suffix if truncated).
  """
  def truncate_title(content) do
    [first | _] = String.split(content, "\n", parts: 2)

    if String.length(first) > 50 do
      String.slice(first, 0, 47) <> "..."
    else
      first
    end
  end

  @doc """
  Parses a page string/integer into a positive integer, defaulting to 1.
  """
  def safe_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  def safe_page(page) when is_integer(page) and page > 0, do: page
  def safe_page(_), do: 1

  @doc """
  Converts raw stream error data into a user-friendly map with :title and :detail.
  """
  def friendly_stream_error("max_retries_exceeded", _msg) do
    %{
      title: "The AI service is currently busy",
      detail: "Too many requests — please wait a moment and retry."
    }
  end

  def friendly_stream_error("request_error", msg) when is_binary(msg) and msg != "" do
    %{
      title: "LLM request failed",
      detail: clean_error_detail(msg)
    }
  end

  def friendly_stream_error(_type, msg) when is_binary(msg) and msg != "" do
    %{
      title: "Something went wrong",
      detail: clean_error_detail(msg)
    }
  end

  def friendly_stream_error(_type, _msg) do
    %{
      title: "Something went wrong",
      detail: "An unexpected error occurred. Please try again."
    }
  end

  @doc """
  Extracts meaningful message from raw struct text that may have leaked into stored errors.
  """
  def clean_error_detail(msg) do
    case Regex.run(~r/"message" => "([^"]+)"/, msg) do
      [_, extracted] ->
        case Regex.run(~r/^HTTP (\d+):/, msg) do
          [_, status] -> "HTTP #{status}: #{extracted}"
          nil -> extracted
        end

      nil ->
        msg
    end
  end

  @doc """
  Formats a tool fetch error into a readable string.
  """
  def format_tool_error(%{status: status, body: body}) when is_binary(body),
    do: "HTTP #{status}: #{String.slice(body, 0..100)}"

  def format_tool_error(%{status: status}), do: "HTTP #{status}"
  def format_tool_error(%Req.TransportError{reason: reason}), do: "Connection error: #{reason}"
  def format_tool_error(reason) when is_binary(reason), do: reason
  def format_tool_error(_reason), do: "unexpected error"

  @doc """
  Filters messages for the edit view — shows messages up to and including the one being edited.
  """
  def display_messages(messages, nil), do: messages

  def display_messages(messages, editing_message_id) do
    Enum.reject(
      Enum.take_while(messages, &(&1.id != editing_message_id)) ++ [Enum.find(messages, &(&1.id == editing_message_id))],
      &is_nil/1
    )
  end
end
