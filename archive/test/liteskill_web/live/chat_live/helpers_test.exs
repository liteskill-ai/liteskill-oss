defmodule LiteskillWeb.ChatLive.HelpersTest do
  use ExUnit.Case, async: true

  alias LiteskillWeb.ChatLive.Helpers

  describe "estimate_tokens/3" do
    test "calculates tokens from cost and model rate" do
      models = [%{id: "m1", input_cost_per_million: Decimal.new("3.00")}]
      # $3 per million tokens, $1 should give ~333_333 tokens
      assert Helpers.estimate_tokens(Decimal.new("1.00"), "m1", models) == 333_333
    end

    test "returns nil for unknown model" do
      assert Helpers.estimate_tokens(Decimal.new("1.00"), "unknown", []) == nil
    end

    test "returns nil when model has nil rate" do
      models = [%{id: "m1", input_cost_per_million: nil}]
      assert Helpers.estimate_tokens(Decimal.new("1.00"), "m1", models) == nil
    end

    test "returns nil when rate is zero" do
      models = [%{id: "m1", input_cost_per_million: Decimal.new("0")}]
      assert Helpers.estimate_tokens(Decimal.new("1.00"), "m1", models) == nil
    end
  end

  describe "estimate_cost/3" do
    test "calculates cost from tokens and model rate" do
      models = [%{id: "m1", input_cost_per_million: Decimal.new("3.00")}]
      result = Helpers.estimate_cost(1_000_000, "m1", models)
      assert Decimal.equal?(result, Decimal.new("3.00"))
    end

    test "returns nil for unknown model" do
      assert Helpers.estimate_cost(1000, "unknown", []) == nil
    end

    test "returns nil when model has nil rate" do
      models = [%{id: "m1", input_cost_per_million: nil}]
      assert Helpers.estimate_cost(1000, "m1", models) == nil
    end
  end

  describe "truncate_title/1" do
    test "returns short single-line content unchanged" do
      assert Helpers.truncate_title("Hello world") == "Hello world"
    end

    test "truncates to 50 chars with ellipsis" do
      long = String.duplicate("a", 60)
      result = Helpers.truncate_title(long)
      assert String.length(result) == 50
      assert String.ends_with?(result, "...")
    end

    test "takes only first line" do
      assert Helpers.truncate_title("First line\nSecond line") == "First line"
    end

    test "handles exactly 50 chars" do
      exactly = String.duplicate("a", 50)
      assert Helpers.truncate_title(exactly) == exactly
    end

    test "handles 51 chars" do
      content = String.duplicate("a", 51)
      result = Helpers.truncate_title(content)
      assert String.length(result) == 50
      assert String.ends_with?(result, "...")
    end
  end

  describe "safe_page/1" do
    test "parses valid page string" do
      assert Helpers.safe_page("3") == 3
    end

    test "returns 1 for invalid string" do
      assert Helpers.safe_page("abc") == 1
    end

    test "returns 1 for zero" do
      assert Helpers.safe_page("0") == 1
    end

    test "returns 1 for negative" do
      assert Helpers.safe_page("-1") == 1
    end

    test "passes through positive integer" do
      assert Helpers.safe_page(5) == 5
    end

    test "returns 1 for zero integer" do
      assert Helpers.safe_page(0) == 1
    end

    test "returns 1 for negative integer" do
      assert Helpers.safe_page(-1) == 1
    end

    test "returns 1 for nil" do
      assert Helpers.safe_page(nil) == 1
    end

    test "returns 1 for string with trailing chars" do
      assert Helpers.safe_page("3abc") == 1
    end
  end

  describe "friendly_stream_error/2" do
    test "max retries exceeded" do
      result = Helpers.friendly_stream_error("max_retries_exceeded", nil)
      assert result.title == "The AI service is currently busy"
    end

    test "request error with message" do
      result = Helpers.friendly_stream_error("request_error", "HTTP 500: server error")
      assert result.title == "LLM request failed"
      assert result.detail == "HTTP 500: server error"
    end

    test "unknown type with message" do
      result = Helpers.friendly_stream_error("some_error", "something broke")
      assert result.title == "Something went wrong"
      assert result.detail == "something broke"
    end

    test "unknown type with nil message" do
      result = Helpers.friendly_stream_error(nil, nil)
      assert result.title == "Something went wrong"
      assert result.detail == "An unexpected error occurred. Please try again."
    end

    test "unknown type with empty message" do
      result = Helpers.friendly_stream_error("other", "")
      assert result.title == "Something went wrong"
      assert result.detail == "An unexpected error occurred. Please try again."
    end
  end

  describe "clean_error_detail/1" do
    test "extracts message from struct text with HTTP status" do
      msg = ~s(HTTP 429: %{"message" => "Rate limit exceeded"})
      assert Helpers.clean_error_detail(msg) == "HTTP 429: Rate limit exceeded"
    end

    test "extracts message from struct text without HTTP prefix" do
      msg = ~s(%{"message" => "Something went wrong"})
      assert Helpers.clean_error_detail(msg) == "Something went wrong"
    end

    test "returns plain message as-is" do
      assert Helpers.clean_error_detail("plain error") == "plain error"
    end
  end

  describe "format_tool_error/1" do
    test "formats HTTP error with body" do
      assert Helpers.format_tool_error(%{status: 500, body: "Internal Server Error"}) ==
               "HTTP 500: Internal Server Error"
    end

    test "formats HTTP error without body" do
      assert Helpers.format_tool_error(%{status: 503}) == "HTTP 503"
    end

    test "formats transport error" do
      error = %Req.TransportError{reason: :timeout}
      assert Helpers.format_tool_error(error) == "Connection error: timeout"
    end

    test "formats string reason" do
      assert Helpers.format_tool_error("custom error") == "custom error"
    end

    test "formats unknown reason" do
      assert Helpers.format_tool_error(:something) == "unexpected error"
    end

    test "truncates long body" do
      long_body = String.duplicate("x", 200)
      result = Helpers.format_tool_error(%{status: 500, body: long_body})
      assert String.starts_with?(result, "HTTP 500: ")
      assert String.length(result) <= 115
    end
  end

  describe "display_messages/2" do
    test "returns all messages when not editing" do
      msgs = [%{id: "1"}, %{id: "2"}, %{id: "3"}]
      assert Helpers.display_messages(msgs, nil) == msgs
    end

    test "filters messages up to and including edited message" do
      msgs = [%{id: "1"}, %{id: "2"}, %{id: "3"}]
      assert Helpers.display_messages(msgs, "2") == [%{id: "1"}, %{id: "2"}]
    end

    test "returns only first message when editing first" do
      msgs = [%{id: "1"}, %{id: "2"}, %{id: "3"}]
      assert Helpers.display_messages(msgs, "1") == [%{id: "1"}]
    end

    test "returns all messages when editing last" do
      msgs = [%{id: "1"}, %{id: "2"}, %{id: "3"}]
      assert Helpers.display_messages(msgs, "3") == msgs
    end

    test "handles non-existent message id" do
      msgs = [%{id: "1"}, %{id: "2"}]
      assert Helpers.display_messages(msgs, "nope") == [%{id: "1"}, %{id: "2"}]
    end
  end
end
