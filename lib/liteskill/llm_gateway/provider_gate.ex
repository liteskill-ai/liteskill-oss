defmodule Liteskill.LlmGateway.ProviderGate do
  @moduledoc """
  Per-provider GenServer implementing circuit breaker + concurrency cap + Retry-After tracking.

  Started lazily via DynamicSupervisor on first use. Looked up via Registry.

  ## Circuit Breaker States

  - `:closed` — normal operation
  - `:open` — error rate exceeded threshold, all checkouts rejected
  - `:half_open` — cooldown expired, one probe request allowed

  ## API

  - `checkout/1` — acquire a slot before an LLM call
  - `checkin/2` — release slot after call completes (pass result)
  - `status/1` — get current gate state for observability
  """

  use GenServer

  require Logger

  @default_max_concurrency 25
  @default_error_threshold 0.5
  @default_min_errors_for_open 5
  @default_circuit_cooldown_ms 30_000
  @error_window_ms 60_000

  # -- Public API --

  @doc """
  Acquires a checkout slot for the given provider.

  Returns `{:ok, checkout_ref}` or `{:error, reason}` where reason is
  `:circuit_open`, `:retry_after`, or `:concurrency_limit`.
  """
  def checkout(provider_id) do
    with {:ok, pid} <- ensure_started(provider_id) do
      GenServer.call(pid, :checkout)
    end
  end

  @doc """
  Releases a checkout slot. Must be called on every terminal path.

  `result` is one of:
  - `:ok` — successful completion
  - `{:error, :retryable, retry_after_ms}` — transient error with backoff hint
  - `{:error, :non_retryable}` — permanent error
  """
  def checkin(provider_id, checkout_ref, result) do
    case lookup(provider_id) do
      {:ok, pid} -> GenServer.cast(pid, {:checkin, checkout_ref, result})
      _ -> :ok
    end
  end

  @doc "Returns the current state of the gate for observability."
  def status(provider_id) do
    case lookup(provider_id) do
      {:ok, pid} -> GenServer.call(pid, :status)
      _ -> {:error, :not_started}
    end
  end

  # -- GenServer lifecycle --

  def start_link(provider_id) do
    GenServer.start_link(__MODULE__, provider_id,
      name: {:via, Registry, {Liteskill.LlmGateway.GateRegistry, provider_id}}
    )
  end

  @impl true
  def init(provider_id) do
    state = %{
      provider_id: provider_id,
      max_concurrency: @default_max_concurrency,
      in_flight: 0,
      active_refs: MapSet.new(),
      ref_monitors: %{},
      circuit_state: :closed,
      retry_after_until: System.monotonic_time(:millisecond),
      error_window: :queue.new(),
      error_threshold: @default_error_threshold,
      min_errors_for_open: @default_min_errors_for_open,
      circuit_cooldown_ms: @default_circuit_cooldown_ms,
      circuit_opened_at: System.monotonic_time(:millisecond),
      half_open_ref: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:checkout, {caller_pid, _} = _from, state) do
    now = System.monotonic_time(:millisecond)

    cond do
      state.retry_after_until > now ->
        deny_retry_after(state, now)

      state.circuit_state == :open ->
        try_transition_half_open(state, now, caller_pid)

      state.circuit_state == :half_open ->
        deny_half_open_in_flight(state)

      state.in_flight >= state.max_concurrency ->
        deny_concurrency(state)

      true ->
        do_checkout(state, caller_pid)
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      provider_id: state.provider_id,
      circuit_state: state.circuit_state,
      in_flight: state.in_flight,
      max_concurrency: state.max_concurrency,
      retry_after_until: state.retry_after_until,
      error_count: :queue.len(state.error_window)
    }

    {:reply, {:ok, status}, state}
  end

  # -- Checkout helpers --

  defp deny_retry_after(state, now) do
    remaining = state.retry_after_until - now

    :telemetry.execute(
      [:liteskill, :llm_gateway, :circuit_opened],
      %{count: 1},
      %{provider_id: state.provider_id, reason: :retry_after}
    )

    {:reply, {:error, :retry_after, remaining}, state}
  end

  defp try_transition_half_open(state, now, caller_pid) do
    if now - state.circuit_opened_at >= state.circuit_cooldown_ms do
      ref = make_ref()
      mon = Process.monitor(caller_pid)

      :telemetry.execute(
        [:liteskill, :llm_gateway, :checkout],
        %{count: 1},
        %{provider_id: state.provider_id, circuit_state: :half_open}
      )

      state = %{
        state
        | circuit_state: :half_open,
          half_open_ref: ref,
          in_flight: state.in_flight + 1,
          active_refs: MapSet.put(state.active_refs, ref),
          ref_monitors: Map.put(state.ref_monitors, ref, mon)
      }

      {:reply, {:ok, ref}, state}
    else
      remaining = state.circuit_cooldown_ms - (now - state.circuit_opened_at)

      :telemetry.execute(
        [:liteskill, :llm_gateway, :circuit_opened],
        %{count: 1},
        %{provider_id: state.provider_id, reason: :circuit_open}
      )

      {:reply, {:error, :circuit_open, remaining}, state}
    end
  end

  defp deny_half_open_in_flight(state) do
    :telemetry.execute(
      [:liteskill, :llm_gateway, :concurrency_limited],
      %{count: 1},
      %{provider_id: state.provider_id, reason: :half_open_probe_in_flight}
    )

    {:reply, {:error, :circuit_open, state.circuit_cooldown_ms}, state}
  end

  defp deny_concurrency(state) do
    :telemetry.execute(
      [:liteskill, :llm_gateway, :concurrency_limited],
      %{count: 1},
      %{provider_id: state.provider_id, reason: :max_concurrency}
    )

    {:reply, {:error, :concurrency_limit}, state}
  end

  defp do_checkout(state, caller_pid) do
    ref = make_ref()
    mon = Process.monitor(caller_pid)

    :telemetry.execute(
      [:liteskill, :llm_gateway, :checkout],
      %{count: 1},
      %{provider_id: state.provider_id, circuit_state: :closed}
    )

    state = %{
      state
      | in_flight: state.in_flight + 1,
        active_refs: MapSet.put(state.active_refs, ref),
        ref_monitors: Map.put(state.ref_monitors, ref, mon)
    }

    {:reply, {:ok, ref}, state}
  end

  @impl true
  def handle_cast({:checkin, ref, result}, state) do
    # Prevent double-checkin via ref matching
    if MapSet.member?(state.active_refs, ref) do
      # Demonitor the caller — they checked in explicitly
      {mon, ref_monitors} = Map.pop(state.ref_monitors, ref)
      if mon, do: Process.demonitor(mon, [:flush])

      state = %{
        state
        | in_flight: max(state.in_flight - 1, 0),
          active_refs: MapSet.delete(state.active_refs, ref),
          ref_monitors: ref_monitors
      }

      :telemetry.execute(
        [:liteskill, :llm_gateway, :checkin],
        %{count: 1},
        %{provider_id: state.provider_id, result: checkin_label(result)}
      )

      state = record_result(state, result)
      state = maybe_transition_circuit(state, ref, result)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, mon_ref, :process, _pid, _reason}, state) do
    # Caller died — find and release their checkout slot.
    # Use :ok result to avoid poisoning the circuit breaker (this is a client
    # cancellation, not a provider error).
    case Enum.find(state.ref_monitors, fn {_ref, m} -> m == mon_ref end) do
      {checkout_ref, _} ->
        ref_monitors = Map.delete(state.ref_monitors, checkout_ref)

        state = %{
          state
          | in_flight: max(state.in_flight - 1, 0),
            active_refs: MapSet.delete(state.active_refs, checkout_ref),
            ref_monitors: ref_monitors
        }

        :telemetry.execute(
          [:liteskill, :llm_gateway, :checkin],
          %{count: 1},
          %{provider_id: state.provider_id, result: "caller_down"}
        )

        state = maybe_transition_circuit(state, checkout_ref, :ok)
        {:noreply, state}

      # coveralls-ignore-next-line — monitor for already-checked-in ref
      nil ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # -- Circuit breaker logic --

  # Specific clause for retryable errors with retry_after hint
  defp record_result(state, {:error, :retryable, retry_after_ms})
       when is_integer(retry_after_ms) and retry_after_ms > 0 do
    now = System.monotonic_time(:millisecond)
    new_until = now + retry_after_ms
    error_window = :queue.in({now, true}, state.error_window)

    %{
      state
      | retry_after_until: max(state.retry_after_until, new_until),
        error_window: prune_window(error_window, now)
    }
  end

  defp record_result(state, result) do
    now = System.monotonic_time(:millisecond)
    is_error = match?({:error, _, _}, result) or match?({:error, _}, result)

    error_window = :queue.in({now, is_error}, state.error_window)
    %{state | error_window: prune_window(error_window, now)}
  end

  defp prune_window(queue, now) do
    cutoff = now - @error_window_ms

    case :queue.peek(queue) do
      {:value, {ts, _}} when ts < cutoff ->
        {_, q} = :queue.out(queue)
        prune_window(q, now)

      _ ->
        queue
    end
  end

  defp maybe_transition_circuit(state, ref, result) do
    case state.circuit_state do
      :half_open ->
        if ref == state.half_open_ref do
          case result do
            :ok ->
              # Probe succeeded — close circuit
              Logger.info("ProviderGate: circuit closed for #{state.provider_id}")

              :telemetry.execute(
                [:liteskill, :llm_gateway, :circuit_closed],
                %{count: 1},
                %{provider_id: state.provider_id}
              )

              %{state | circuit_state: :closed, half_open_ref: nil, error_window: :queue.new()}

            _ ->
              # Probe failed — reopen circuit
              open_circuit(state)
          end
        else
          # coveralls-ignore-next-line — non-probe checkin during half_open
          state
        end

      :closed ->
        maybe_open_circuit(state)

      :open ->
        state
    end
  end

  defp maybe_open_circuit(state) do
    entries = :queue.to_list(state.error_window)
    total = length(entries)
    errors = Enum.count(entries, fn {_, is_error} -> is_error end)

    if total >= state.min_errors_for_open &&
         errors / total >= state.error_threshold do
      open_circuit(state)
    else
      state
    end
  end

  defp open_circuit(state) do
    now = System.monotonic_time(:millisecond)
    Logger.warning("ProviderGate: circuit opened for #{state.provider_id}")

    :telemetry.execute(
      [:liteskill, :llm_gateway, :circuit_opened],
      %{count: 1},
      %{provider_id: state.provider_id, reason: :error_rate}
    )

    %{state | circuit_state: :open, circuit_opened_at: now, half_open_ref: nil}
  end

  defp checkin_label(:ok), do: "ok"
  defp checkin_label({:error, :retryable, _}), do: "retryable"
  defp checkin_label({:error, :non_retryable}), do: "non_retryable"
  # coveralls-ignore-next-line
  defp checkin_label(_), do: "unknown"

  # -- DynamicSupervisor helpers --

  defp ensure_started(provider_id) do
    case lookup(provider_id) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        case DynamicSupervisor.start_child(
               Liteskill.LlmGateway.GateSupervisor,
               {__MODULE__, provider_id}
             ) do
          {:ok, pid} -> {:ok, pid}
          # coveralls-ignore-next-line — race condition handler
          {:error, {:already_started, pid}} -> {:ok, pid}
        end
    end
  rescue
    # DynamicSupervisor not started yet
    # coveralls-ignore-next-line
    ArgumentError -> {:error, :gateway_not_available}
  end

  defp lookup(provider_id) do
    case Registry.lookup(Liteskill.LlmGateway.GateRegistry, provider_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  rescue
    # Registry not started yet (app boot or supervision tree not restarted)
    # coveralls-ignore-next-line
    ArgumentError -> :error
  end
end
