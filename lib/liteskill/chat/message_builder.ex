defmodule Liteskill.Chat.MessageBuilder do
  @moduledoc """
  Builds LLM-compatible message lists from stored conversation messages.

  Transforms projected Message records (with tool_calls) into the format
  expected by the LLM layer: lists of `%{"role" => ..., "content" => [...]}`.
  """

  alias Liteskill.Repo

  import Ecto.Query

  @doc """
  Converts a list of Message records into LLM message format.

  Preloads tool_calls, filters to complete messages, reconstructs
  toolUse/toolResult pairs, and merges consecutive same-role messages.
  """
  def build_llm_messages(messages) do
    messages
    |> Repo.preload(:tool_calls)
    |> Enum.filter(&(&1.status == "complete"))
    |> Enum.reduce([], fn msg, acc ->
      case msg.role do
        "user" ->
          if msg.content && msg.content != "" do
            acc ++ [%{"role" => "user", "content" => [%{"text" => msg.content}]}]
          else
            acc
          end

        "assistant" ->
          build_assistant_message(msg, acc)
      end
    end)
    |> merge_consecutive_roles()
  end

  defp build_assistant_message(msg, acc) do
    if msg.stop_reason == "tool_use" do
      text_blocks =
        if msg.content && msg.content != "" do
          [%{"text" => msg.content}]
        else
          []
        end

      completed_tcs = Enum.filter(msg.tool_calls, &(&1.status == "completed"))

      tool_use_blocks =
        Enum.map(msg.tool_calls, fn tc ->
          %{
            "toolUse" => %{
              "toolUseId" => tc.tool_use_id,
              "name" => tc.tool_name,
              "input" => tc.input || %{}
            }
          }
        end)

      content = text_blocks ++ tool_use_blocks
      assistant_msg = %{"role" => "assistant", "content" => content}

      if completed_tcs != [] do
        tool_results =
          Enum.map(completed_tcs, fn tc ->
            %{
              "toolResult" => %{
                "toolUseId" => tc.tool_use_id,
                "content" => [%{"text" => format_tool_output(tc.output)}],
                "status" => "success"
              }
            }
          end)

        acc ++ [assistant_msg, %{"role" => "user", "content" => tool_results}]
      else
        acc ++ [assistant_msg]
      end
    else
      if msg.content && msg.content != "" do
        acc ++ [%{"role" => "assistant", "content" => [%{"text" => msg.content}]}]
      else
        acc
      end
    end
  end

  @doc """
  Loads tool calls for a message, handling the case where the
  association is not yet preloaded.
  """
  def tool_calls_for_message(msg) do
    case msg.tool_calls do
      %Ecto.Association.NotLoaded{} ->
        Repo.all(
          from tc in Liteskill.Chat.ToolCall,
            where: tc.message_id == ^msg.id,
            order_by: [asc: tc.inserted_at]
        )

      tool_calls ->
        tool_calls
    end
  end

  # Merge consecutive same-role messages (can happen when failed assistant
  # messages are filtered out, leaving adjacent user messages).
  defp merge_consecutive_roles(messages) do
    messages
    |> Enum.chunk_while(
      nil,
      fn msg, acc ->
        case acc do
          nil ->
            {:cont, msg}

          %{"role" => role} ->
            if role == msg["role"] do
              merged = %{acc | "content" => acc["content"] ++ msg["content"]}
              {:cont, merged}
            else
              {:cont, acc, msg}
            end
        end
      end,
      fn
        nil -> {:cont, []}
        acc -> {:cont, acc, nil}
      end
    )
  end

  @doc """
  Strips toolUse and toolResult blocks from LLM messages, keeping only text.

  Bedrock returns HTTP 400 if messages contain toolUse blocks but no tools
  configuration is provided. This is used when retrying a conversation that
  previously used tools but currently has no tools selected.
  """
  def strip_tool_blocks(messages) do
    messages
    |> Enum.map(fn msg ->
      content =
        msg["content"]
        |> Enum.filter(fn
          %{"toolUse" => _} -> false
          %{"toolResult" => _} -> false
          _ -> true
        end)

      %{msg | "content" => content}
    end)
    |> Enum.reject(fn msg -> msg["content"] == [] end)
    |> merge_consecutive_roles()
  end

  defp format_tool_output(nil), do: ""

  defp format_tool_output(%{"content" => content}) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{"text" => text} -> text
      other -> Jason.encode!(other)
    end)
  end

  defp format_tool_output(output) when is_map(output), do: Jason.encode!(output)
  defp format_tool_output(output), do: inspect(output)
end
