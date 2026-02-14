defmodule Liteskill.InstancesTest do
  use Liteskill.DataCase, async: true

  alias Liteskill.Instances
  alias Liteskill.Instances.{Instance, InstanceTask}
  alias Liteskill.Teams

  setup do
    {:ok, owner} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "inst-owner-#{System.unique_integer([:positive])}@example.com",
        name: "Instance Owner",
        oidc_sub: "inst-owner-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, other} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "inst-other-#{System.unique_integer([:positive])}@example.com",
        name: "Other User",
        oidc_sub: "inst-other-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    {:ok, team} =
      Teams.create_team(%{
        name: "Inst Team #{System.unique_integer([:positive])}",
        user_id: owner.id
      })

    %{owner: owner, other: other, team: team}
  end

  defp instance_attrs(user, overrides \\ %{}) do
    Map.merge(
      %{
        name: "Instance #{System.unique_integer([:positive])}",
        prompt: "Test prompt for the instance",
        topology: "pipeline",
        user_id: user.id
      },
      overrides
    )
  end

  describe "create_instance/1" do
    test "creates an instance with owner ACL", %{owner: owner} do
      attrs = instance_attrs(owner)
      assert {:ok, instance} = Instances.create_instance(attrs)

      assert instance.name == attrs.name
      assert instance.prompt == "Test prompt for the instance"
      assert instance.topology == "pipeline"
      assert instance.status == "pending"
      assert instance.user_id == owner.id
      assert instance.instance_tasks == []

      assert Liteskill.Authorization.is_owner?("instance", instance.id, owner.id)
    end

    test "creates instance with team assignment", %{owner: owner, team: team} do
      attrs = instance_attrs(owner, %{team_definition_id: team.id})
      assert {:ok, instance} = Instances.create_instance(attrs)
      assert instance.team_definition_id == team.id
      assert instance.team_definition.id == team.id
    end

    test "validates required fields" do
      assert {:error, changeset} = Instances.create_instance(%{})
      errors = errors_on(changeset)
      assert "can't be blank" in errors.name
      assert "can't be blank" in errors.prompt
      assert "can't be blank" in errors.user_id
    end

    test "validates topology inclusion", %{owner: owner} do
      attrs = instance_attrs(owner, %{topology: "invalid"})
      assert {:error, changeset} = Instances.create_instance(attrs)
      assert "is invalid" in errors_on(changeset).topology
    end

    test "validates status inclusion", %{owner: owner} do
      attrs = instance_attrs(owner, %{status: "bogus"})
      assert {:error, changeset} = Instances.create_instance(attrs)
      assert "is invalid" in errors_on(changeset).status
    end

    test "defaults are applied", %{owner: owner} do
      assert {:ok, instance} = Instances.create_instance(instance_attrs(owner))
      assert instance.timeout_ms == 1_800_000
      assert instance.max_iterations == 50
      assert instance.context == %{}
      assert instance.deliverables == %{}
    end
  end

  describe "update_instance/3" do
    test "updates instance as owner", %{owner: owner} do
      {:ok, instance} = Instances.create_instance(instance_attrs(owner))

      assert {:ok, updated} =
               Instances.update_instance(instance.id, owner.id, %{status: "running"})

      assert updated.status == "running"
    end

    test "returns not_found for missing instance", %{owner: owner} do
      assert {:error, :not_found} =
               Instances.update_instance(Ecto.UUID.generate(), owner.id, %{})
    end

    test "returns forbidden for non-owner", %{owner: owner, other: other} do
      {:ok, instance} = Instances.create_instance(instance_attrs(owner))

      assert {:error, :forbidden} =
               Instances.update_instance(instance.id, other.id, %{status: "running"})
    end

    test "preloads associations on update", %{owner: owner} do
      {:ok, instance} = Instances.create_instance(instance_attrs(owner))

      {:ok, updated} =
        Instances.update_instance(instance.id, owner.id, %{description: "Updated"})

      assert is_list(updated.instance_tasks)
    end

    test "returns changeset error for invalid update", %{owner: owner} do
      {:ok, instance} = Instances.create_instance(instance_attrs(owner))

      assert {:error, %Ecto.Changeset{}} =
               Instances.update_instance(instance.id, owner.id, %{topology: "invalid"})
    end
  end

  describe "delete_instance/2" do
    test "deletes instance as owner", %{owner: owner} do
      {:ok, instance} = Instances.create_instance(instance_attrs(owner))
      assert {:ok, _} = Instances.delete_instance(instance.id, owner.id)
      assert {:error, :not_found} = Instances.get_instance(instance.id, owner.id)
    end

    test "returns not_found for missing instance", %{owner: owner} do
      assert {:error, :not_found} = Instances.delete_instance(Ecto.UUID.generate(), owner.id)
    end

    test "returns forbidden for non-owner", %{owner: owner, other: other} do
      {:ok, instance} = Instances.create_instance(instance_attrs(owner))
      assert {:error, :forbidden} = Instances.delete_instance(instance.id, other.id)
    end
  end

  describe "list_instances/1" do
    test "lists user's own instances", %{owner: owner} do
      {:ok, i1} = Instances.create_instance(instance_attrs(owner))
      {:ok, i2} = Instances.create_instance(instance_attrs(owner))

      instances = Instances.list_instances(owner.id)
      ids = Enum.map(instances, & &1.id)
      assert i1.id in ids
      assert i2.id in ids
    end

    test "returns empty for user with no instances", %{other: other} do
      assert Instances.list_instances(other.id) == []
    end

    test "includes instances shared via ACL", %{owner: owner, other: other} do
      {:ok, instance} = Instances.create_instance(instance_attrs(owner))

      Liteskill.Authorization.grant_access(
        "instance",
        instance.id,
        owner.id,
        other.id,
        "viewer"
      )

      instances = Instances.list_instances(other.id)
      assert length(instances) == 1
      assert hd(instances).id == instance.id
    end
  end

  describe "get_instance/2" do
    test "returns instance for owner", %{owner: owner} do
      {:ok, instance} = Instances.create_instance(instance_attrs(owner))
      assert {:ok, found} = Instances.get_instance(instance.id, owner.id)
      assert found.id == instance.id
    end

    test "returns not_found for missing ID", %{owner: owner} do
      assert {:error, :not_found} = Instances.get_instance(Ecto.UUID.generate(), owner.id)
    end

    test "returns not_found for non-owner without ACL", %{owner: owner, other: other} do
      {:ok, instance} = Instances.create_instance(instance_attrs(owner))
      assert {:error, :not_found} = Instances.get_instance(instance.id, other.id)
    end

    test "returns instance for user with ACL", %{owner: owner, other: other} do
      {:ok, instance} = Instances.create_instance(instance_attrs(owner))

      Liteskill.Authorization.grant_access(
        "instance",
        instance.id,
        owner.id,
        other.id,
        "viewer"
      )

      assert {:ok, found} = Instances.get_instance(instance.id, other.id)
      assert found.id == instance.id
    end
  end

  describe "get_instance!/1" do
    test "returns instance without auth check", %{owner: owner} do
      {:ok, instance} = Instances.create_instance(instance_attrs(owner))
      found = Instances.get_instance!(instance.id)
      assert found.id == instance.id
    end
  end

  describe "add_task/2" do
    test "creates a task for an instance", %{owner: owner} do
      {:ok, instance} = Instances.create_instance(instance_attrs(owner))

      assert {:ok, task} =
               Instances.add_task(instance.id, %{
                 name: "Stage 1",
                 description: "First step",
                 status: "running",
                 position: 0,
                 started_at: DateTime.utc_now()
               })

      assert task.name == "Stage 1"
      assert task.instance_id == instance.id
      assert task.status == "running"
      assert task.position == 0
    end

    test "validates required fields", %{owner: owner} do
      {:ok, instance} = Instances.create_instance(instance_attrs(owner))
      assert {:error, changeset} = Instances.add_task(instance.id, %{})
      assert "can't be blank" in errors_on(changeset).name
    end
  end

  describe "update_task/2" do
    test "updates a task", %{owner: owner} do
      {:ok, instance} = Instances.create_instance(instance_attrs(owner))
      {:ok, task} = Instances.add_task(instance.id, %{name: "Step 1"})

      assert {:ok, updated} =
               Instances.update_task(task.id, %{
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
               Instances.update_task(Ecto.UUID.generate(), %{status: "failed"})
    end
  end

  describe "Instance schema" do
    test "valid_topologies returns expected values" do
      topologies = Instance.valid_topologies()
      assert "pipeline" in topologies
      assert "parallel" in topologies
    end

    test "valid_statuses returns expected values" do
      statuses = Instance.valid_statuses()
      assert "pending" in statuses
      assert "completed" in statuses
      assert "failed" in statuses
    end
  end

  describe "InstanceTask.changeset/2" do
    test "validates required fields" do
      changeset = InstanceTask.changeset(%InstanceTask{}, %{})
      refute changeset.valid?
      errors = errors_on(changeset)
      assert "can't be blank" in errors.name
      assert "can't be blank" in errors.instance_id
    end

    test "validates status inclusion" do
      changeset =
        InstanceTask.changeset(%InstanceTask{}, %{
          name: "test",
          instance_id: Ecto.UUID.generate(),
          status: "bogus"
        })

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).status
    end
  end
end
