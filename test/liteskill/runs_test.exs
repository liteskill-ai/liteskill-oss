defmodule Liteskill.RunsTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Runs
  alias Liteskill.Runs.{Run, RunLog, RunTask}
  alias Liteskill.Teams

  setup do
    {:ok, owner} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "run-owner-#{System.unique_integer([:positive])}@example.com",
        name: "Run Owner",
        oidc_sub: "run-owner-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, other} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "run-other-#{System.unique_integer([:positive])}@example.com",
        name: "Other User",
        oidc_sub: "run-other-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, team} =
      Teams.create_team(%{
        name: "Run Team #{System.unique_integer([:positive])}",
        user_id: owner.id
      })

    %{owner: owner, other: other, team: team}
  end

  defp run_attrs(user, overrides \\ %{}) do
    Map.merge(
      %{
        name: "Run #{System.unique_integer([:positive])}",
        prompt: "Test prompt for the run",
        topology: "pipeline",
        user_id: user.id
      },
      overrides
    )
  end

  describe "create_run/1" do
    test "creates a run with owner ACL", %{owner: owner} do
      attrs = run_attrs(owner)
      assert {:ok, run} = Runs.create_run(attrs)

      assert run.name == attrs.name
      assert run.prompt == "Test prompt for the run"
      assert run.topology == "pipeline"
      assert run.status == "pending"
      assert run.user_id == owner.id
      assert run.run_tasks == []

      assert Liteskill.Authorization.owner?("run", run.id, owner.id)
    end

    test "creates run with team assignment", %{owner: owner, team: team} do
      attrs = run_attrs(owner, %{team_definition_id: team.id})
      assert {:ok, run} = Runs.create_run(attrs)
      assert run.team_definition_id == team.id
      assert run.team_definition.id == team.id
    end

    test "rejects create without user_id" do
      assert {:error, :forbidden} = Runs.create_run(%{})
    end

    test "validates required fields", %{owner: owner} do
      assert {:error, changeset} = Runs.create_run(%{user_id: owner.id})
      errors = errors_on(changeset)
      assert "can't be blank" in errors.name
      assert "can't be blank" in errors.prompt
    end

    test "validates topology inclusion", %{owner: owner} do
      attrs = run_attrs(owner, %{topology: "invalid"})
      assert {:error, changeset} = Runs.create_run(attrs)
      assert "is invalid" in errors_on(changeset).topology
    end

    test "validates status inclusion", %{owner: owner} do
      attrs = run_attrs(owner, %{status: "bogus"})
      assert {:error, changeset} = Runs.create_run(attrs)
      assert "is invalid" in errors_on(changeset).status
    end

    test "defaults are applied", %{owner: owner} do
      assert {:ok, run} = Runs.create_run(run_attrs(owner))
      assert run.timeout_ms == 3_600_000
      assert run.max_iterations == 50
      assert run.context == %{}
      assert run.deliverables == %{}
    end
  end

  describe "update_run/3" do
    test "updates run as owner", %{owner: owner} do
      {:ok, run} = Runs.create_run(run_attrs(owner))

      assert {:ok, updated} =
               Runs.update_run(run.id, owner.id, %{status: "running"})

      assert updated.status == "running"
    end

    test "returns not_found for missing run", %{owner: owner} do
      assert {:error, :not_found} =
               Runs.update_run(Ecto.UUID.generate(), owner.id, %{})
    end

    test "returns forbidden for non-owner", %{owner: owner, other: other} do
      {:ok, run} = Runs.create_run(run_attrs(owner))

      assert {:error, :forbidden} =
               Runs.update_run(run.id, other.id, %{status: "running"})
    end

    test "preloads associations on update", %{owner: owner} do
      {:ok, run} = Runs.create_run(run_attrs(owner))

      {:ok, updated} =
        Runs.update_run(run.id, owner.id, %{description: "Updated"})

      assert is_list(updated.run_tasks)
    end

    test "returns changeset error for invalid update", %{owner: owner} do
      {:ok, run} = Runs.create_run(run_attrs(owner))

      assert {:error, %Ecto.Changeset{}} =
               Runs.update_run(run.id, owner.id, %{topology: "invalid"})
    end
  end

  describe "delete_run/2" do
    test "deletes run as owner", %{owner: owner} do
      {:ok, run} = Runs.create_run(run_attrs(owner))
      assert {:ok, _} = Runs.delete_run(run.id, owner.id)
      assert {:error, :not_found} = Runs.get_run(run.id, owner.id)
    end

    test "returns not_found for missing run", %{owner: owner} do
      assert {:error, :not_found} = Runs.delete_run(Ecto.UUID.generate(), owner.id)
    end

    test "returns forbidden for non-owner", %{owner: owner, other: other} do
      {:ok, run} = Runs.create_run(run_attrs(owner))
      assert {:error, :forbidden} = Runs.delete_run(run.id, other.id)
    end
  end

  describe "cancel_run/2" do
    test "cancels a running run", %{owner: owner} do
      {:ok, run} = Runs.create_run(run_attrs(owner))
      {:ok, run} = Runs.update_run(run.id, owner.id, %{status: "running"})

      assert {:ok, cancelled} = Runs.cancel_run(run.id, owner.id)
      assert cancelled.status == "cancelled"
      assert cancelled.completed_at != nil
    end

    test "returns not_running for pending run", %{owner: owner} do
      {:ok, run} = Runs.create_run(run_attrs(owner))

      assert {:error, :not_running} = Runs.cancel_run(run.id, owner.id)
    end

    test "returns not_running for completed run", %{owner: owner} do
      {:ok, run} = Runs.create_run(run_attrs(owner))
      {:ok, run} = Runs.update_run(run.id, owner.id, %{status: "completed"})

      assert {:error, :not_running} = Runs.cancel_run(run.id, owner.id)
    end

    test "returns not_found for missing run", %{owner: owner} do
      assert {:error, :not_found} = Runs.cancel_run(Ecto.UUID.generate(), owner.id)
    end

    test "returns forbidden for non-owner", %{owner: owner, other: other} do
      {:ok, run} = Runs.create_run(run_attrs(owner))
      {:ok, _run} = Runs.update_run(run.id, owner.id, %{status: "running"})

      assert {:error, :forbidden} = Runs.cancel_run(run.id, other.id)
    end
  end

  describe "list_runs/1" do
    test "lists user's own runs", %{owner: owner} do
      {:ok, r1} = Runs.create_run(run_attrs(owner))
      {:ok, r2} = Runs.create_run(run_attrs(owner))

      runs = Runs.list_runs(owner.id)
      ids = Enum.map(runs, & &1.id)
      assert r1.id in ids
      assert r2.id in ids
    end

    test "returns empty for user with no runs", %{other: other} do
      assert Runs.list_runs(other.id) == []
    end

    test "includes runs shared via ACL", %{owner: owner, other: other} do
      {:ok, run} = Runs.create_run(run_attrs(owner))

      Liteskill.Authorization.grant_access(
        "run",
        run.id,
        owner.id,
        other.id,
        "viewer"
      )

      runs = Runs.list_runs(other.id)
      assert length(runs) == 1
      assert hd(runs).id == run.id
    end
  end

  describe "get_run/2" do
    test "returns run for owner", %{owner: owner} do
      {:ok, run} = Runs.create_run(run_attrs(owner))
      assert {:ok, found} = Runs.get_run(run.id, owner.id)
      assert found.id == run.id
    end

    test "returns not_found for missing ID", %{owner: owner} do
      assert {:error, :not_found} = Runs.get_run(Ecto.UUID.generate(), owner.id)
    end

    test "returns not_found for non-owner without ACL", %{owner: owner, other: other} do
      {:ok, run} = Runs.create_run(run_attrs(owner))
      assert {:error, :not_found} = Runs.get_run(run.id, other.id)
    end

    test "returns run for user with ACL", %{owner: owner, other: other} do
      {:ok, run} = Runs.create_run(run_attrs(owner))

      Liteskill.Authorization.grant_access(
        "run",
        run.id,
        owner.id,
        other.id,
        "viewer"
      )

      assert {:ok, found} = Runs.get_run(run.id, other.id)
      assert found.id == run.id
    end
  end

  describe "get_run!/1" do
    test "returns run without auth check", %{owner: owner} do
      {:ok, run} = Runs.create_run(run_attrs(owner))
      found = Runs.get_run!(run.id)
      assert found.id == run.id
    end
  end

  describe "add_task/2" do
    test "creates a task for a run", %{owner: owner} do
      {:ok, run} = Runs.create_run(run_attrs(owner))

      assert {:ok, task} =
               Runs.add_task(run.id, %{
                 name: "Stage 1",
                 description: "First step",
                 status: "running",
                 position: 0,
                 started_at: DateTime.utc_now()
               })

      assert task.name == "Stage 1"
      assert task.run_id == run.id
      assert task.status == "running"
      assert task.position == 0
    end

    test "validates required fields", %{owner: owner} do
      {:ok, run} = Runs.create_run(run_attrs(owner))
      assert {:error, changeset} = Runs.add_task(run.id, %{})
      assert "can't be blank" in errors_on(changeset).name
    end
  end

  describe "update_task/2" do
    test "updates a task", %{owner: owner} do
      {:ok, run} = Runs.create_run(run_attrs(owner))
      {:ok, task} = Runs.add_task(run.id, %{name: "Step 1"})

      assert {:ok, updated} =
               Runs.update_task(task.id, %{
                 status: "completed",
                 output_summary: "Done",
                 duration_ms: 42
               })

      assert updated.status == "completed"
      assert updated.output_summary == "Done"
      assert updated.duration_ms == 42
    end

    test "returns not_found for missing task" do
      assert {:error, :not_found} =
               Runs.update_task(Ecto.UUID.generate(), %{status: "failed"})
    end
  end

  describe "Run schema" do
    test "valid_topologies returns expected values" do
      topologies = Run.valid_topologies()
      assert "pipeline" in topologies
      assert "parallel" in topologies
    end

    test "valid_statuses returns expected values" do
      statuses = Run.valid_statuses()
      assert "pending" in statuses
      assert "completed" in statuses
      assert "failed" in statuses
    end
  end

  describe "add_log/5" do
    test "creates a log entry for a run", %{owner: owner} do
      {:ok, run} = Runs.create_run(run_attrs(owner))

      assert {:ok, log} = Runs.add_log(run.id, "info", "init", "Started")
      assert log.level == "info"
      assert log.step == "init"
      assert log.message == "Started"
      assert log.metadata == %{}
      assert log.run_id == run.id
    end

    test "creates a log entry with metadata", %{owner: owner} do
      {:ok, run} = Runs.create_run(run_attrs(owner))

      assert {:ok, log} =
               Runs.add_log(run.id, "error", "crash", "Failed", %{"key" => "val"})

      assert log.metadata == %{"key" => "val"}
    end
  end

  describe "get_log/2" do
    test "returns log for owner", %{owner: owner} do
      {:ok, run} = Runs.create_run(run_attrs(owner))
      {:ok, log} = Runs.add_log(run.id, "info", "init", "Started")

      assert {:ok, found} = Runs.get_log(log.id, owner.id)
      assert found.id == log.id
      assert found.run.id == run.id
    end

    test "returns not_found for missing ID", %{owner: owner} do
      assert {:error, :not_found} = Runs.get_log(Ecto.UUID.generate(), owner.id)
    end

    test "returns not_found for non-owner without ACL", %{owner: owner, other: other} do
      {:ok, run} = Runs.create_run(run_attrs(owner))
      {:ok, log} = Runs.add_log(run.id, "info", "init", "Started")

      assert {:error, :not_found} = Runs.get_log(log.id, other.id)
    end

    test "returns log for user with ACL access", %{owner: owner, other: other} do
      {:ok, run} = Runs.create_run(run_attrs(owner))
      {:ok, log} = Runs.add_log(run.id, "info", "init", "Started")

      Liteskill.Authorization.grant_access(
        "run",
        run.id,
        owner.id,
        other.id,
        "viewer"
      )

      assert {:ok, found} = Runs.get_log(log.id, other.id)
      assert found.id == log.id
    end
  end

  describe "subscribe/1 and unsubscribe/1" do
    test "subscribe and unsubscribe complete without error", %{owner: owner} do
      {:ok, run} = Runs.create_run(run_attrs(owner))

      assert :ok = Runs.subscribe(run.id)
      assert :ok = Runs.unsubscribe(run.id)
    end
  end

  describe "add_log/5 error path" do
    test "returns error for invalid level", %{owner: owner} do
      {:ok, run} = Runs.create_run(run_attrs(owner))

      assert {:error, changeset} = Runs.add_log(run.id, "bogus", "init", "Started")
      assert "is invalid" in errors_on(changeset).level
    end
  end

  describe "RunLog.changeset/2" do
    test "validates required fields" do
      changeset = RunLog.changeset(%RunLog{}, %{})
      refute changeset.valid?
      errors = errors_on(changeset)
      assert "can't be blank" in errors.level
      assert "can't be blank" in errors.step
      assert "can't be blank" in errors.message
      assert "can't be blank" in errors.run_id
    end

    test "validates level inclusion" do
      changeset =
        RunLog.changeset(%RunLog{}, %{
          level: "bogus",
          step: "init",
          message: "test",
          run_id: Ecto.UUID.generate()
        })

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).level
    end
  end

  describe "RunTask.changeset/2" do
    test "validates required fields" do
      changeset = RunTask.changeset(%RunTask{}, %{})
      refute changeset.valid?
      errors = errors_on(changeset)
      assert "can't be blank" in errors.name
      assert "can't be blank" in errors.run_id
    end

    test "validates status inclusion" do
      changeset =
        RunTask.changeset(%RunTask{}, %{
          name: "test",
          run_id: Ecto.UUID.generate(),
          status: "bogus"
        })

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).status
    end
  end
end
