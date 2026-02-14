defmodule Liteskill.Instances do
  @moduledoc """
  Context for managing instances — runtime task executions.

  Each instance represents a single run: it has a prompt, optional team,
  topology, and tracks its lifecycle from pending through completed/failed.
  """

  alias Liteskill.Instances.{Instance, InstanceTask}
  alias Liteskill.Authorization
  alias Liteskill.Repo

  import Ecto.Query

  # --- CRUD ---

  def create_instance(attrs) do
    Repo.transaction(fn ->
      case %Instance{}
           |> Instance.changeset(attrs)
           |> Repo.insert() do
        {:ok, instance} ->
          {:ok, _} =
            Authorization.create_owner_acl("instance", instance.id, instance.user_id)

          Repo.preload(instance, [:team_definition, :instance_tasks])

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  def update_instance(id, user_id, attrs) do
    case Repo.get(Instance, id) do
      nil ->
        {:error, :not_found}

      instance ->
        with {:ok, instance} <- authorize_owner(instance, user_id) do
          instance
          |> Instance.changeset(attrs)
          |> Repo.update()
          |> case do
            {:ok, updated} ->
              {:ok, Repo.preload(updated, [:team_definition, :instance_tasks])}

            error ->
              error
          end
        end
    end
  end

  def delete_instance(id, user_id) do
    case Repo.get(Instance, id) do
      nil ->
        {:error, :not_found}

      instance ->
        with {:ok, instance} <- authorize_owner(instance, user_id) do
          Repo.delete(instance)
        end
    end
  end

  # --- Queries ---

  def list_instances(user_id) do
    accessible_ids = Authorization.accessible_entity_ids("instance", user_id)

    Instance
    |> where([i], i.user_id == ^user_id or i.id in subquery(accessible_ids))
    |> order_by([i], desc: i.inserted_at)
    |> preload([:team_definition, :instance_tasks])
    |> Repo.all()
  end

  def get_instance(id, user_id) do
    case Repo.get(Instance, id) |> Repo.preload([:team_definition, :instance_tasks]) do
      nil ->
        {:error, :not_found}

      %Instance{user_id: ^user_id} = instance ->
        {:ok, instance}

      %Instance{} = instance ->
        if Authorization.has_access?("instance", instance.id, user_id) do
          {:ok, instance}
        else
          {:error, :not_found}
        end
    end
  end

  def get_instance!(id) do
    Repo.get!(Instance, id) |> Repo.preload([:team_definition, :instance_tasks])
  end

  # --- Instance Tasks ---

  def add_task(instance_id, attrs) do
    %InstanceTask{}
    |> InstanceTask.changeset(Map.put(attrs, :instance_id, instance_id))
    |> Repo.insert()
  end

  def update_task(task_id, attrs) do
    case Repo.get(InstanceTask, task_id) do
      nil -> {:error, :not_found}
      task -> task |> InstanceTask.changeset(attrs) |> Repo.update()
    end
  end

  # --- Private ---

  defp authorize_owner(%Instance{user_id: user_id} = instance, user_id), do: {:ok, instance}
  defp authorize_owner(_, _), do: {:error, :forbidden}
end
