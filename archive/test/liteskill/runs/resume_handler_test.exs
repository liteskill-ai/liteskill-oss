defmodule Liteskill.Runs.ResumeHandlerTest do
  use ExUnit.Case, async: true

  alias Liteskill.Runs.ResumeHandler

  describe "extract_handoff_summary/1" do
    test "extracts ## Handoff Summary section" do
      output = """
      Some analysis output here.

      ## Handoff Summary
      - Found 5 key issues
      - Recommended 3 actions
      - Next agent should focus on implementation
      """

      result = ResumeHandler.extract_handoff_summary(output)
      assert result =~ "Found 5 key issues"
      assert result =~ "Recommended 3 actions"
      assert result =~ "Next agent should focus on implementation"
    end

    test "extracts ### Handoff Summary section" do
      output = "Analysis.\n\n### Handoff Summary\n- bullet one\n- bullet two"
      result = ResumeHandler.extract_handoff_summary(output)
      assert result =~ "bullet one"
      assert result =~ "bullet two"
    end

    test "stops at next ## section header" do
      output = """
      Some preamble.

      ## Handoff Summary
      - Key finding one
      - Key finding two

      ## Conclusion
      This should NOT be in the summary.
      """

      result = ResumeHandler.extract_handoff_summary(output)
      assert result =~ "Key finding one"
      assert result =~ "Key finding two"
      refute result =~ "Conclusion"
      refute result =~ "should NOT be in the summary"
    end

    test "falls back to first 500 chars when no section present" do
      output = String.duplicate("a", 1000)
      result = ResumeHandler.extract_handoff_summary(output)
      assert String.length(result) == 500
      assert result == String.duplicate("a", 500)
    end

    test "truncates long handoff summaries to 500 chars" do
      long_summary = String.duplicate("x", 1000)
      output = "## Handoff Summary\n#{long_summary}"
      result = ResumeHandler.extract_handoff_summary(output)
      assert String.length(result) == 500
    end

    test "returns empty string for nil" do
      assert ResumeHandler.extract_handoff_summary(nil) == ""
    end

    test "returns empty string for non-binary" do
      assert ResumeHandler.extract_handoff_summary(42) == ""
    end

    test "handles empty string" do
      assert ResumeHandler.extract_handoff_summary("") == ""
    end

    test "handles summary at end of string with no trailing newline" do
      output = "## Handoff Summary\n- only item"
      result = ResumeHandler.extract_handoff_summary(output)
      assert result == "- only item"
    end
  end

  describe "find_handoff_summary/2" do
    test "returns handoff_summary from metadata when present" do
      logs = [
        log("agent_complete", "Agent1", %{
          "agent" => "Agent1",
          "handoff_summary" => "Summary from metadata"
        })
      ]

      assert ResumeHandler.find_handoff_summary(logs, "Agent1") == "Summary from metadata"
    end

    test "falls back to extracting from output when no handoff_summary key" do
      logs = [
        log("agent_complete", "Agent1", %{
          "agent" => "Agent1",
          "output" => "Some text\n\n## Handoff Summary\n- Extracted from output"
        })
      ]

      result = ResumeHandler.find_handoff_summary(logs, "Agent1")
      assert result =~ "Extracted from output"
    end

    test "returns nil when no matching log entry" do
      logs = [
        log("agent_complete", "Agent2", %{"agent" => "Agent2", "handoff_summary" => "Other"})
      ]

      assert ResumeHandler.find_handoff_summary(logs, "Agent1") == nil
    end

    test "returns nil for empty logs" do
      assert ResumeHandler.find_handoff_summary([], "Agent1") == nil
    end

    test "picks the most recent log entry" do
      logs = [
        log("agent_complete", "Agent1", %{
          "agent" => "Agent1",
          "handoff_summary" => "Old summary"
        }),
        log(
          "agent_complete",
          "Agent1",
          %{"agent" => "Agent1", "handoff_summary" => "New summary"},
          ~U[2026-01-02 00:00:00Z]
        )
      ]

      assert ResumeHandler.find_handoff_summary(logs, "Agent1") == "New summary"
    end

    test "ignores non-agent_complete log entries" do
      logs = [
        log("agent_crash", "Agent1", %{
          "agent" => "Agent1",
          "handoff_summary" => "Crash summary"
        }),
        log("agent_complete", "Agent1", %{
          "agent" => "Agent1",
          "handoff_summary" => "Complete summary"
        })
      ]

      assert ResumeHandler.find_handoff_summary(logs, "Agent1") == "Complete summary"
    end
  end

  describe "find_crash_messages/2" do
    test "returns messages from crash log" do
      messages = [%{"role" => "system", "content" => "test"}]

      logs = [
        log("agent_crash", "Agent1", %{"agent" => "Agent1", "messages" => messages})
      ]

      assert ResumeHandler.find_crash_messages(logs, "Agent1") == messages
    end

    test "returns nil when no crash log" do
      logs = [
        log("agent_complete", "Agent1", %{"agent" => "Agent1", "output" => "done"})
      ]

      assert ResumeHandler.find_crash_messages(logs, "Agent1") == nil
    end

    test "returns nil for empty logs" do
      assert ResumeHandler.find_crash_messages([], "Agent1") == nil
    end

    test "returns nil when crash log is for different agent" do
      logs = [
        log("agent_crash", "Agent2", %{
          "agent" => "Agent2",
          "messages" => [%{"role" => "system"}]
        })
      ]

      assert ResumeHandler.find_crash_messages(logs, "Agent1") == nil
    end

    test "picks the most recent crash log" do
      logs = [
        log(
          "agent_crash",
          "Agent1",
          %{"agent" => "Agent1", "messages" => [%{"role" => "old"}]},
          ~U[2026-01-01 00:00:00Z]
        ),
        log(
          "agent_crash",
          "Agent1",
          %{"agent" => "Agent1", "messages" => [%{"role" => "new"}]},
          ~U[2026-01-02 00:00:00Z]
        )
      ]

      assert ResumeHandler.find_crash_messages(logs, "Agent1") == [%{"role" => "new"}]
    end

    test "returns nil when crash log has no messages key" do
      logs = [
        log("agent_crash", "Agent1", %{"agent" => "Agent1"})
      ]

      assert ResumeHandler.find_crash_messages(logs, "Agent1") == nil
    end
  end

  # Build a fake log struct that matches the fields ResumeHandler reads
  defp log(step, agent_name, metadata, inserted_at \\ ~U[2026-01-01 00:00:00Z]) do
    %{
      step: step,
      metadata: Map.put_new(metadata, "agent", agent_name),
      inserted_at: inserted_at
    }
  end
end
