defmodule Liteskill.Schedules do
  use Boundary,
    top_level?: true,
    deps: [Liteskill.Authorization, Liteskill.Rbac, Liteskill.Runs],
    exports: [Schedule, ScheduleTick, ScheduleWorker]

  @moduledoc """
  Context for managing schedules — cron-like recurring run execution.

  Each schedule defines a cron expression and run template that creates
  runs on a recurring basis.
  """

  alias Liteskill.Schedules.Schedule
  alias Liteskill.Authorization
  alias Liteskill.Repo

  import Ecto.Query

  # --- CRUD ---

  def create_schedule(attrs) do
    user_id = attrs[:user_id] || attrs["user_id"]

    with :ok <- Liteskill.Rbac.authorize(user_id, "schedules:create") do
      changeset =
        %Schedule{}
        |> Schedule.changeset(attrs)
        |> maybe_set_next_run_at()

      Authorization.create_with_owner_acl(changeset, "schedule", [:team_definition])
    end
  end

  defp maybe_set_next_run_at(changeset) do
    cron = Ecto.Changeset.get_field(changeset, :cron_expression)
    tz = Ecto.Changeset.get_field(changeset, :timezone) || "UTC"
    enabled = Ecto.Changeset.get_field(changeset, :enabled)
    existing = Ecto.Changeset.get_field(changeset, :next_run_at)

    if cron && enabled && is_nil(existing) do
      case compute_next_run(cron, tz) do
        nil -> changeset
        next -> Ecto.Changeset.put_change(changeset, :next_run_at, next)
      end
    else
      changeset
    end
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

  # --- Schedule Execution ---

  @doc """
  Returns all enabled schedules whose `next_run_at` is at or before `now`.
  """
  def list_due_schedules(now \\ DateTime.utc_now()) do
    Schedule
    |> where([s], s.enabled == true and s.status == "active")
    |> where([s], not is_nil(s.next_run_at) and s.next_run_at <= ^now)
    |> Repo.all()
  end

  @doc """
  Computes the next run time from a cron expression and timezone.

  Uses a simple field-matching approach for standard 5-field cron expressions
  (minute hour day-of-month month day-of-week). Returns a UTC `DateTime`.
  """
  def compute_next_run(cron_expression, timezone \\ "UTC", from \\ DateTime.utc_now()) do
    case parse_cron(cron_expression) do
      {:ok, cron} ->
        from
        |> shift_to_timezone(timezone)
        |> next_match(cron, 0)
        |> shift_from_timezone(timezone)

      :error ->
        nil
    end
  end

  # Simple cron parser for 5-field expressions: minute hour dom month dow
  defp parse_cron(expr) do
    parts = String.split(expr)

    if length(parts) >= 5 do
      [minute, hour, dom, month, dow | _] = parts

      {:ok,
       %{
         minute: parse_field(minute, 0, 59),
         hour: parse_field(hour, 0, 23),
         dom: parse_field(dom, 1, 31),
         month: parse_field(month, 1, 12),
         dow: parse_field(dow, 0, 6)
       }}
    else
      :error
    end
  end

  defp parse_field("*", _min, _max), do: :any

  defp parse_field("*/" <> step, min, max) do
    case Integer.parse(step) do
      {n, ""} when n > 0 -> {:step, n, min, max}
      # coveralls-ignore-next-line
      _ -> :any
    end
  end

  defp parse_field(val, _min, _max) do
    case String.split(val, ",") do
      [single] ->
        case Integer.parse(single) do
          {n, ""} -> {:exact, [n]}
          _ -> :any
        end

      multiple ->
        values =
          Enum.flat_map(multiple, fn v ->
            case Integer.parse(v) do
              {n, ""} -> [n]
              _ -> []
            end
          end)

        if values != [], do: {:exact, values}, else: :any
    end
  end

  defp field_matches?(:any, _val), do: true
  defp field_matches?({:exact, values}, val), do: val in values
  defp field_matches?({:step, step, min, _max}, val), do: rem(val - min, step) == 0

  # coveralls-ignore-start
  defp next_match(_dt, _cron, attempts) when attempts > 525_960 do
    # Safety valve: don't scan more than ~1 year of minutes
    nil
  end

  # coveralls-ignore-stop

  defp next_match(dt, cron, attempts) do
    candidate = NaiveDateTime.add(dt, (attempts + 1) * 60, :second)
    dow = Date.day_of_week(NaiveDateTime.to_date(candidate)) |> rem(7)

    if field_matches?(cron.minute, candidate.minute) &&
         field_matches?(cron.hour, candidate.hour) &&
         field_matches?(cron.dom, candidate.day) &&
         field_matches?(cron.month, candidate.month) &&
         field_matches?(cron.dow, dow) do
      # Truncate seconds to 0
      %{candidate | second: 0, microsecond: {0, 0}}
    else
      next_match(dt, cron, attempts + 1)
    end
  end

  defp shift_to_timezone(dt, "UTC"), do: DateTime.to_naive(dt)

  defp shift_to_timezone(dt, tz) do
    case DateTime.shift_zone(dt, tz) do
      {:ok, shifted} -> DateTime.to_naive(shifted)
      # coveralls-ignore-next-line
      _ -> DateTime.to_naive(dt)
    end
  end

  # coveralls-ignore-next-line
  defp shift_from_timezone(nil, _tz), do: nil

  defp shift_from_timezone(naive, "UTC") do
    DateTime.from_naive!(naive, "Etc/UTC")
  end

  defp shift_from_timezone(naive, tz) do
    case DateTime.from_naive(naive, tz) do
      {:ok, dt} ->
        case DateTime.shift_zone(dt, "Etc/UTC") do
          {:ok, utc} -> utc
          # coveralls-ignore-next-line
          _ -> DateTime.from_naive!(naive, "Etc/UTC")
        end

      # coveralls-ignore-start
      _ ->
        DateTime.from_naive!(naive, "Etc/UTC")
        # coveralls-ignore-stop
    end
  end

  # --- Private ---

  defp authorize_owner(entity, user_id), do: Authorization.authorize_owner(entity, user_id)
end
