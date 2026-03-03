defmodule Liteskill.Schedules.ScheduleTickTest do
  use Liteskill.DataCase, async: false
  use Oban.Testing, repo: Liteskill.Repo

  alias Liteskill.Schedules
  alias Liteskill.Schedules.ScheduleTick

  setup do
    {:ok, owner} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "sched-tick-#{System.unique_integer([:positive])}@example.com",
        name: "Tick Owner",
        oidc_sub: "sched-tick-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{owner: owner}
  end

  describe "handle_info/2" do
    test "enqueues workers for due schedules", %{owner: owner} do
      {:ok, team} =
        Liteskill.Teams.create_team(%{
          name: "Tick Team #{System.unique_integer([:positive])}",
          user_id: owner.id
        })

      {:ok, agent} =
        Liteskill.Agents.create_agent(%{
          name: "Tick Agent #{System.unique_integer([:positive])}",
          strategy: "direct",
          system_prompt: "Test",
          backstory: "Test",
          user_id: owner.id
        })

      {:ok, _member} = Liteskill.Teams.add_member(team.id, agent.id, owner.id, %{role: "worker"})

      past = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)

      {:ok, _schedule} =
        Schedules.create_schedule(%{
          name: "Due Schedule #{System.unique_integer([:positive])}",
          cron_expression: "* * * * *",
          prompt: "Test prompt",
          enabled: true,
          team_definition_id: team.id,
          user_id: owner.id,
          next_run_at: past
        })

      # Manually trigger tick
      assert {:noreply, %{}} = ScheduleTick.handle_info(:tick, %{})

      # Verify a ScheduleWorker job was enqueued
      assert_enqueued(worker: Liteskill.Schedules.ScheduleWorker)
    end

    test "handles error gracefully when no due schedules" do
      assert {:noreply, %{}} = ScheduleTick.handle_info(:tick, %{})
    end
  end

  describe "init/1" do
    test "starts and schedules a tick" do
      # start_supervised! to ensure cleanup
      pid = start_supervised!({ScheduleTick, []})
      assert Process.alive?(pid)

      # The GenServer should have scheduled a :tick message
      # We can verify by sending a tick directly
      send(pid, :tick)
      # Give it a moment to process
      _ = :sys.get_state(pid)
      assert Process.alive?(pid)
    end
  end
end
