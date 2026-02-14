defmodule Liteskill.Schedules do
  @moduledoc """
  Context for managing schedules — cron-like recurring instance execution.

  Each schedule defines a cron expression and instance template that creates
  instances on a recurring basis.
  """

  alias Liteskill.Schedules.Schedule
  alias Liteskill.Authorization
  alias Liteskill.Repo

  import Ecto.Query

  # --- CRUD ---

  def create_schedule(attrs) do
    Repo.transaction(fn ->
      case %Schedule{}
           |> Schedule.changeset(attrs)
           |> Repo.insert() do
        {:ok, schedule} ->
          {:ok, _} =
            Authorization.create_owner_acl("schedule", schedule.id, schedule.user_id)

          Repo.preload(schedule, :team_definition)

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  def update_schedule(id, user_id, attrs) do
    case Repo.get(Schedule, id) do
      nil ->
        {:error, :not_found}

      schedule ->
        with {:ok, schedule} <- authorize_owner(schedule, user_id) do
          schedule
          |> Schedule.changeset(attrs)
          |> Repo.update()
          |> case do
            {:ok, updated} -> {:ok, Repo.preload(updated, :team_definition)}
            error -> error
          end
        end
    end
  end

  def delete_schedule(id, user_id) do
    case Repo.get(Schedule, id) do
      nil ->
        {:error, :not_found}

      schedule ->
        with {:ok, schedule} <- authorize_owner(schedule, user_id) do
          Repo.delete(schedule)
        end
    end
  end

  # --- Queries ---

  def list_schedules(user_id) do
    accessible_ids = Authorization.accessible_entity_ids("schedule", user_id)

    Schedule
    |> where([s], s.user_id == ^user_id or s.id in subquery(accessible_ids))
    |> order_by([s], asc: s.name)
    |> preload(:team_definition)
    |> Repo.all()
  end

  def get_schedule(id, user_id) do
    case Repo.get(Schedule, id) |> Repo.preload(:team_definition) do
      nil ->
        {:error, :not_found}

      %Schedule{user_id: ^user_id} = schedule ->
        {:ok, schedule}

      %Schedule{} = schedule ->
        if Authorization.has_access?("schedule", schedule.id, user_id) do
          {:ok, schedule}
        else
          {:error, :not_found}
        end
    end
  end

  def get_schedule!(id) do
    Repo.get!(Schedule, id) |> Repo.preload(:team_definition)
  end

  def toggle_schedule(id, user_id) do
    case Repo.get(Schedule, id) do
      nil ->
        {:error, :not_found}

      schedule ->
        with {:ok, schedule} <- authorize_owner(schedule, user_id) do
          schedule
          |> Schedule.changeset(%{enabled: !schedule.enabled})
          |> Repo.update()
        end
    end
  end

  # --- Private ---

  defp authorize_owner(%Schedule{user_id: user_id} = schedule, user_id), do: {:ok, schedule}
  defp authorize_owner(_, _), do: {:error, :forbidden}
end
