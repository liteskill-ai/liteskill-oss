defmodule Liteskill.Runs do
  use Boundary,
    top_level?: true,
    deps: [
      Liteskill.Authorization,
      Liteskill.Rbac,
      Liteskill.Agents,
      Liteskill.Teams,
      Liteskill.Usage,
      Liteskill.BuiltinTools
    ],
    exports: [Run, RunLog, RunTask, Runner, ReportBuilder, ResumeHandler]

  @moduledoc """
  Context for managing runs — runtime task executions.

  Each run represents a single execution: it has a prompt, optional team,
  topology, and tracks its lifecycle from pending through completed/failed.
  """

  alias Liteskill.Runs.{Run, RunLog, RunTask}
  alias Liteskill.Authorization
  alias Liteskill.Repo

  import Ecto.Query

  # --- CRUD ---

  def create_run(attrs) do
    user_id = attrs[:user_id] || attrs["user_id"]

    with :ok <- Liteskill.Rbac.authorize(user_id, "runs:create") do
      %Run{}
      |> Run.changeset(attrs)
      |> Authorization.create_with_owner_acl("run", [:team_definition, :run_tasks, :run_logs])
    end
  end

  def update_run(id, user_id, attrs) do
    case Repo.get(Run, id) do
      nil ->
        {:error, :not_found}

      run ->
        with {:ok, run} <- authorize_owner(run, user_id) do
          run
          |> Run.changeset(attrs)
          |> Repo.update()
          |> case do
            {:ok, updated} ->
              updated = Repo.preload(updated, [:team_definition, :run_tasks, :run_logs])
              broadcast_run_update(updated)
              {:ok, updated}

            error ->
              error
          end
        end
    end
  end

  def delete_run(id, user_id) do
    case Repo.get(Run, id) do
      nil ->
        {:error, :not_found}

      run ->
        with {:ok, run} <- authorize_owner(run, user_id) do
          Repo.delete(run)
        end
    end
  end

  def cancel_run(id, user_id) do
    case Repo.get(Run, id) do
      nil ->
        {:error, :not_found}

      %Run{status: "running"} = run ->
        with {:ok, run} <- authorize_owner(run, user_id) do
          result =
            run
            |> Run.changeset(%{status: "cancelled", completed_at: DateTime.utc_now()})
            |> Repo.update()

          case result do
            {:ok, updated} ->
              broadcast_run_update(updated)

            # coveralls-ignore-start
            _ ->
              :ok
              # coveralls-ignore-stop
          end

          result
        end

      %Run{} ->
        {:error, :not_running}
    end
  end

  # --- Queries ---

  def list_runs(user_id) do
    accessible_ids = Authorization.accessible_entity_ids("run", user_id)

    Run
    |> where([r], r.user_id == ^user_id or r.id in subquery(accessible_ids))
    |> order_by([r], desc: r.inserted_at)
    |> preload([:team_definition, :run_tasks, :run_logs])
    |> Repo.all()
  end

  def get_run(id, user_id) do
    case Repo.get(Run, id)
         |> Repo.preload([:team_definition, :run_tasks, :run_logs]) do
      nil ->
        {:error, :not_found}

      %Run{user_id: ^user_id} = run ->
        {:ok, run}

      %Run{} = run ->
        if Authorization.has_access?("run", run.id, user_id) do
          {:ok, run}
        else
          {:error, :not_found}
        end
    end
  end

  def get_run!(id) do
    Repo.get!(Run, id) |> Repo.preload([:team_definition, :run_tasks, :run_logs])
  end

  # --- Run Tasks ---

  def add_task(run_id, attrs) do
    %RunTask{}
    |> RunTask.changeset(Map.put(attrs, :run_id, run_id))
    |> Repo.insert()
  end

  def update_task(task_id, attrs) do
    case Repo.get(RunTask, task_id) do
      nil -> {:error, :not_found}
      task -> task |> RunTask.changeset(attrs) |> Repo.update()
    end
  end

  # --- Run Logs ---

  def get_log(log_id, user_id) do
    case Repo.get(RunLog, log_id) |> Repo.preload(:run) do
      nil ->
        {:error, :not_found}

      %RunLog{run: %Run{user_id: ^user_id}} = log ->
        {:ok, log}

      %RunLog{run: run} = log ->
        if Authorization.has_access?("run", run.id, user_id) do
          {:ok, log}
        else
          {:error, :not_found}
        end
    end
  end

  def add_log(run_id, level, step, message, metadata \\ %{}) do
    result =
      %RunLog{}
      |> RunLog.changeset(%{
        run_id: run_id,
        level: level,
        step: step,
        message: message,
        metadata: metadata
      })
      |> Repo.insert()

    case result do
      {:ok, log} ->
        broadcast_run_log(run_id, log)
        {:ok, log}

      error ->
        error
    end
  end

  # --- PubSub ---

  @pubsub Liteskill.PubSub

  def subscribe(run_id) do
    Phoenix.PubSub.subscribe(@pubsub, "runs:#{run_id}")
  end

  def unsubscribe(run_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, "runs:#{run_id}")
  end

  defp broadcast_run_update(run) do
    Phoenix.PubSub.broadcast(@pubsub, "runs:#{run.id}", {:run_updated, run})
  end

  defp broadcast_run_log(run_id, log) do
    Phoenix.PubSub.broadcast(@pubsub, "runs:#{run_id}", {:run_log_added, log})
  end

  # --- Private ---

  defp authorize_owner(entity, user_id), do: Authorization.authorize_owner(entity, user_id)
end
