defmodule Liteskill.Schedules.ScheduleWorkerTest do
  use Liteskill.DataCase, async: false
  use Oban.Testing, repo: Liteskill.Repo

  alias Liteskill.Schedules
  alias Liteskill.Schedules.ScheduleWorker

  setup do
    {:ok, owner} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "sched-worker-#{System.unique_integer([:positive])}@example.com",
        name: "Schedule Owner",
        oidc_sub: "sched-worker-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    # Create a team with an agent for the schedule
    {:ok, agent} =
      Liteskill.Agents.create_agent(%{
        name: "Sched Agent #{System.unique_integer([:positive])}",
        strategy: "direct",
        system_prompt: "You are a test agent.",
        backstory: "Test",
        user_id: owner.id
      })

    {:ok, team} =
      Liteskill.Teams.create_team(%{
        name: "Sched Team #{System.unique_integer([:positive])}",
        user_id: owner.id
      })

    {:ok, _member} = Liteskill.Teams.add_member(team.id, agent.id, owner.id, %{role: "analyst"})

    %{owner: owner, team: team}
  end

  describe "perform/1" do
    test "skips disabled schedule", %{owner: owner, team: team} do
      {:ok, schedule} =
        Schedules.create_schedule(%{
          name: "Disabled Schedule",
          cron_expression: "0 * * * *",
          prompt: "Test prompt",
          enabled: false,
          team_definition_id: team.id,
          user_id: owner.id
        })

      job = %Oban.Job{args: %{"schedule_id" => schedule.id, "user_id" => owner.id}}
      assert :ok = ScheduleWorker.perform(job)
    end

    test "returns :ok for missing schedule", %{owner: owner} do
      fake_id = Ecto.UUID.generate()
      job = %Oban.Job{args: %{"schedule_id" => fake_id, "user_id" => owner.id}}
      assert :ok = ScheduleWorker.perform(job)
    end

    test "creates run for enabled schedule", %{owner: owner, team: team} do
      {:ok, schedule} =
        Schedules.create_schedule(%{
          name: "Enabled Schedule #{System.unique_integer([:positive])}",
          cron_expression: "0 * * * *",
          prompt: "Run this test",
          enabled: true,
          team_definition_id: team.id,
          user_id: owner.id
        })

      job = %Oban.Job{args: %{"schedule_id" => schedule.id, "user_id" => owner.id}}

      # The run will fail because the agent has no LLM model, but the worker
      # still returns :ok after creating the run and kicking off the task.
      assert :ok = ScheduleWorker.perform(job)

      # Verify run was created
      runs = Liteskill.Runs.list_runs(owner.id)
      assert runs != []
      assert Enum.any?(runs, fn r -> String.starts_with?(r.name, "Enabled Schedule") end)
    end
  end
end
