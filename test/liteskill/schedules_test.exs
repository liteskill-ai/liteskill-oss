defmodule Liteskill.SchedulesTest do
  use Liteskill.DataCase, async: true

  alias Liteskill.Schedules
  alias Liteskill.Schedules.Schedule

  setup do
    {:ok, owner} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "sched-owner-#{System.unique_integer([:positive])}@example.com",
        name: "Schedule Owner",
        oidc_sub: "sched-owner-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, other} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "sched-other-#{System.unique_integer([:positive])}@example.com",
        name: "Other User",
        oidc_sub: "sched-other-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{owner: owner, other: other}
  end

  defp schedule_attrs(user, overrides \\ %{}) do
    Map.merge(
      %{
        name: "Schedule #{System.unique_integer([:positive])}",
        description: "A test schedule",
        cron_expression: "0 9 * * *",
        timezone: "UTC",
        prompt: "Run daily analysis",
        topology: "pipeline",
        user_id: user.id
      },
      overrides
    )
  end

  describe "create_schedule/1" do
    test "creates a schedule with owner ACL", %{owner: owner} do
      attrs = schedule_attrs(owner)
      assert {:ok, schedule} = Schedules.create_schedule(attrs)

      assert schedule.name == attrs.name
      assert schedule.cron_expression == "0 9 * * *"
      assert schedule.timezone == "UTC"
      assert schedule.prompt == "Run daily analysis"
      assert schedule.topology == "pipeline"
      assert schedule.enabled == true
      assert schedule.status == "active"
      assert schedule.user_id == owner.id

      assert Liteskill.Authorization.is_owner?("schedule", schedule.id, owner.id)
    end

    test "validates required fields" do
      assert {:error, changeset} = Schedules.create_schedule(%{})
      errors = errors_on(changeset)
      assert "can't be blank" in errors.name
      assert "can't be blank" in errors.cron_expression
      assert "can't be blank" in errors.prompt
      assert "can't be blank" in errors.user_id
    end

    test "validates cron expression format", %{owner: owner} do
      attrs = schedule_attrs(owner, %{cron_expression: "not a cron"})
      assert {:error, changeset} = Schedules.create_schedule(attrs)

      assert "must be a valid cron expression (5 or 6 fields)" in errors_on(changeset).cron_expression
    end

    test "accepts 5-field cron expression", %{owner: owner} do
      attrs = schedule_attrs(owner, %{cron_expression: "0 9 * * 1"})
      assert {:ok, schedule} = Schedules.create_schedule(attrs)
      assert schedule.cron_expression == "0 9 * * 1"
    end

    test "accepts 6-field cron expression", %{owner: owner} do
      attrs = schedule_attrs(owner, %{cron_expression: "0 0 9 * * 1"})
      assert {:ok, schedule} = Schedules.create_schedule(attrs)
      assert schedule.cron_expression == "0 0 9 * * 1"
    end

    test "validates topology inclusion", %{owner: owner} do
      attrs = schedule_attrs(owner, %{topology: "invalid"})
      assert {:error, changeset} = Schedules.create_schedule(attrs)
      assert "is invalid" in errors_on(changeset).topology
    end

    test "validates status inclusion", %{owner: owner} do
      attrs = schedule_attrs(owner, %{status: "bogus"})
      assert {:error, changeset} = Schedules.create_schedule(attrs)
      assert "is invalid" in errors_on(changeset).status
    end

    test "enforces unique name per user", %{owner: owner} do
      attrs = schedule_attrs(owner, %{name: "Unique Schedule"})
      assert {:ok, _} = Schedules.create_schedule(attrs)
      assert {:error, changeset} = Schedules.create_schedule(attrs)
      assert "has already been taken" in errors_on(changeset).name
    end
  end

  describe "update_schedule/3" do
    test "updates schedule as owner", %{owner: owner} do
      {:ok, schedule} = Schedules.create_schedule(schedule_attrs(owner))

      assert {:ok, updated} =
               Schedules.update_schedule(schedule.id, owner.id, %{name: "Renamed"})

      assert updated.name == "Renamed"
    end

    test "returns not_found for missing schedule", %{owner: owner} do
      assert {:error, :not_found} =
               Schedules.update_schedule(Ecto.UUID.generate(), owner.id, %{})
    end

    test "returns forbidden for non-owner", %{owner: owner, other: other} do
      {:ok, schedule} = Schedules.create_schedule(schedule_attrs(owner))

      assert {:error, :forbidden} =
               Schedules.update_schedule(schedule.id, other.id, %{name: "Nope"})
    end

    test "returns changeset error for invalid update", %{owner: owner} do
      {:ok, schedule} = Schedules.create_schedule(schedule_attrs(owner))

      assert {:error, %Ecto.Changeset{}} =
               Schedules.update_schedule(schedule.id, owner.id, %{topology: "invalid"})
    end

    test "preloads team_definition on update", %{owner: owner} do
      {:ok, schedule} = Schedules.create_schedule(schedule_attrs(owner))

      {:ok, updated} =
        Schedules.update_schedule(schedule.id, owner.id, %{description: "Updated"})

      assert updated.team_definition == nil
    end
  end

  describe "delete_schedule/2" do
    test "deletes schedule as owner", %{owner: owner} do
      {:ok, schedule} = Schedules.create_schedule(schedule_attrs(owner))
      assert {:ok, _} = Schedules.delete_schedule(schedule.id, owner.id)
      assert {:error, :not_found} = Schedules.get_schedule(schedule.id, owner.id)
    end

    test "returns not_found for missing schedule", %{owner: owner} do
      assert {:error, :not_found} = Schedules.delete_schedule(Ecto.UUID.generate(), owner.id)
    end

    test "returns forbidden for non-owner", %{owner: owner, other: other} do
      {:ok, schedule} = Schedules.create_schedule(schedule_attrs(owner))
      assert {:error, :forbidden} = Schedules.delete_schedule(schedule.id, other.id)
    end
  end

  describe "list_schedules/1" do
    test "lists user's own schedules", %{owner: owner} do
      {:ok, s1} = Schedules.create_schedule(schedule_attrs(owner, %{name: "Alpha Schedule"}))
      {:ok, s2} = Schedules.create_schedule(schedule_attrs(owner, %{name: "Beta Schedule"}))

      schedules = Schedules.list_schedules(owner.id)
      ids = Enum.map(schedules, & &1.id)
      assert s1.id in ids
      assert s2.id in ids
    end

    test "returns empty for user with no schedules", %{other: other} do
      assert Schedules.list_schedules(other.id) == []
    end

    test "includes schedules shared via ACL", %{owner: owner, other: other} do
      {:ok, schedule} = Schedules.create_schedule(schedule_attrs(owner))

      Liteskill.Authorization.grant_access(
        "schedule",
        schedule.id,
        owner.id,
        other.id,
        "viewer"
      )

      schedules = Schedules.list_schedules(other.id)
      assert length(schedules) == 1
      assert hd(schedules).id == schedule.id
    end
  end

  describe "get_schedule/2" do
    test "returns schedule for owner", %{owner: owner} do
      {:ok, schedule} = Schedules.create_schedule(schedule_attrs(owner))
      assert {:ok, found} = Schedules.get_schedule(schedule.id, owner.id)
      assert found.id == schedule.id
    end

    test "returns not_found for missing ID", %{owner: owner} do
      assert {:error, :not_found} = Schedules.get_schedule(Ecto.UUID.generate(), owner.id)
    end

    test "returns not_found for non-owner without ACL", %{owner: owner, other: other} do
      {:ok, schedule} = Schedules.create_schedule(schedule_attrs(owner))
      assert {:error, :not_found} = Schedules.get_schedule(schedule.id, other.id)
    end

    test "returns schedule for user with ACL", %{owner: owner, other: other} do
      {:ok, schedule} = Schedules.create_schedule(schedule_attrs(owner))

      Liteskill.Authorization.grant_access(
        "schedule",
        schedule.id,
        owner.id,
        other.id,
        "viewer"
      )

      assert {:ok, found} = Schedules.get_schedule(schedule.id, other.id)
      assert found.id == schedule.id
    end
  end

  describe "get_schedule!/1" do
    test "returns schedule without auth check", %{owner: owner} do
      {:ok, schedule} = Schedules.create_schedule(schedule_attrs(owner))
      found = Schedules.get_schedule!(schedule.id)
      assert found.id == schedule.id
    end
  end

  describe "toggle_schedule/2" do
    test "toggles enabled from true to false", %{owner: owner} do
      {:ok, schedule} = Schedules.create_schedule(schedule_attrs(owner))
      assert schedule.enabled == true

      assert {:ok, toggled} = Schedules.toggle_schedule(schedule.id, owner.id)
      assert toggled.enabled == false
    end

    test "toggles enabled from false to true", %{owner: owner} do
      {:ok, schedule} = Schedules.create_schedule(schedule_attrs(owner, %{enabled: false}))

      assert {:ok, toggled} = Schedules.toggle_schedule(schedule.id, owner.id)
      assert toggled.enabled == true
    end

    test "returns not_found for missing schedule", %{owner: owner} do
      assert {:error, :not_found} = Schedules.toggle_schedule(Ecto.UUID.generate(), owner.id)
    end

    test "returns forbidden for non-owner", %{owner: owner, other: other} do
      {:ok, schedule} = Schedules.create_schedule(schedule_attrs(owner))
      assert {:error, :forbidden} = Schedules.toggle_schedule(schedule.id, other.id)
    end
  end

  describe "Schedule schema" do
    test "valid_topologies returns expected values" do
      assert "pipeline" in Schedule.valid_topologies()
    end

    test "changeset skips cron validation when no change" do
      changeset =
        Schedule.changeset(
          %Schedule{cron_expression: "0 * * * *"},
          %{name: "test", prompt: "do stuff", user_id: Ecto.UUID.generate()}
        )

      assert changeset.valid?
    end
  end
end
