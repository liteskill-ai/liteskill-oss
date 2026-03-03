defmodule Liteskill.LlmGateway.ProviderGateTest do
  use ExUnit.Case, async: true

  alias Liteskill.LlmGateway.ProviderGate

  defp unique_provider_id, do: "provider-#{System.unique_integer([:positive])}"

  defp start_gate(provider_id) do
    start_supervised!({ProviderGate, provider_id},
      id: {ProviderGate, provider_id}
    )
  end

  test "checkout and checkin basic flow" do
    provider_id = unique_provider_id()
    start_gate(provider_id)

    assert {:ok, ref} = ProviderGate.checkout(provider_id)
    assert is_reference(ref)

    :ok = ProviderGate.checkin(provider_id, ref, :ok)

    {:ok, status} = ProviderGate.status(provider_id)
    assert status.in_flight == 0
    assert status.circuit_state == :closed
  end

  test "concurrency limit is enforced" do
    provider_id = unique_provider_id()
    start_gate(provider_id)

    # Checkout up to max (default 25)
    refs =
      for _ <- 1..25 do
        {:ok, ref} = ProviderGate.checkout(provider_id)
        ref
      end

    # 26th should fail
    assert {:error, :concurrency_limit} = ProviderGate.checkout(provider_id)

    # Check one back in, should allow again
    ProviderGate.checkin(provider_id, hd(refs), :ok)
    assert {:ok, _ref} = ProviderGate.checkout(provider_id)
  end

  test "circuit opens after error threshold exceeded" do
    provider_id = unique_provider_id()
    start_gate(provider_id)

    # Generate errors to trip the circuit (need >= 5 errors with >= 50% rate)
    # Checkout all refs first, then checkin all — avoids circuit opening mid-loop
    refs =
      for _ <- 1..6 do
        {:ok, ref} = ProviderGate.checkout(provider_id)
        ref
      end

    for ref <- refs do
      ProviderGate.checkin(provider_id, ref, {:error, :non_retryable})
    end

    {:ok, status} = ProviderGate.status(provider_id)
    assert status.circuit_state == :open
  end

  test "circuit transitions to half_open after cooldown" do
    provider_id = unique_provider_id()
    pid = start_gate(provider_id)

    # Trip the circuit — checkout all first, then checkin all
    refs =
      for _ <- 1..6 do
        {:ok, ref} = ProviderGate.checkout(provider_id)
        ref
      end

    for ref <- refs do
      ProviderGate.checkin(provider_id, ref, {:error, :non_retryable})
    end

    # Fast-forward the circuit cooldown by manipulating state
    :sys.replace_state(pid, fn state ->
      %{state | circuit_opened_at: System.monotonic_time(:millisecond) - 31_000}
    end)

    # Should get a checkout (half_open probe)
    assert {:ok, ref} = ProviderGate.checkout(provider_id)

    {:ok, status} = ProviderGate.status(provider_id)
    assert status.circuit_state == :half_open

    # Second checkout during half_open should be rejected
    assert {:error, :circuit_open, _} = ProviderGate.checkout(provider_id)

    # Successful probe closes circuit
    ProviderGate.checkin(provider_id, ref, :ok)

    {:ok, status} = ProviderGate.status(provider_id)
    assert status.circuit_state == :closed
  end

  test "half_open probe failure reopens circuit" do
    provider_id = unique_provider_id()
    pid = start_gate(provider_id)

    # Trip the circuit — checkout all first, then checkin all
    refs =
      for _ <- 1..6 do
        {:ok, ref} = ProviderGate.checkout(provider_id)
        ref
      end

    for ref <- refs do
      ProviderGate.checkin(provider_id, ref, {:error, :non_retryable})
    end

    # Fast-forward cooldown
    :sys.replace_state(pid, fn state ->
      %{state | circuit_opened_at: System.monotonic_time(:millisecond) - 31_000}
    end)

    {:ok, ref} = ProviderGate.checkout(provider_id)

    # Failed probe reopens
    ProviderGate.checkin(provider_id, ref, {:error, :non_retryable})

    {:ok, status} = ProviderGate.status(provider_id)
    assert status.circuit_state == :open
  end

  test "retry_after blocks checkouts" do
    provider_id = unique_provider_id()
    pid = start_gate(provider_id)

    # Simulate a retry_after by setting the state
    :sys.replace_state(pid, fn state ->
      %{state | retry_after_until: System.monotonic_time(:millisecond) + 5_000}
    end)

    assert {:error, :retry_after, remaining} = ProviderGate.checkout(provider_id)
    assert remaining > 0
    assert remaining <= 5_000
  end

  test "retryable checkin with positive retry_after_ms sets retry_after_until" do
    provider_id = unique_provider_id()
    _pid = start_gate(provider_id)

    {:ok, status_before} = ProviderGate.status(provider_id)
    initial = status_before.retry_after_until

    {:ok, ref} = ProviderGate.checkout(provider_id)
    ProviderGate.checkin(provider_id, ref, {:error, :retryable, 5_000})

    {:ok, status} = ProviderGate.status(provider_id)
    # retry_after_until should have been extended from initial value
    assert status.retry_after_until > initial
    # The retry_after should block checkouts
    assert {:error, :retry_after, _} = ProviderGate.checkout(provider_id)
  end

  test "double checkin with same ref is idempotent" do
    provider_id = unique_provider_id()
    start_gate(provider_id)

    {:ok, ref} = ProviderGate.checkout(provider_id)
    ProviderGate.checkin(provider_id, ref, :ok)
    # Second checkin with same ref should be a no-op
    ProviderGate.checkin(provider_id, ref, :ok)

    {:ok, status} = ProviderGate.status(provider_id)
    assert status.in_flight == 0
  end

  test "checkin to non-started provider is a no-op" do
    :ok = ProviderGate.checkin("nonexistent-provider", make_ref(), :ok)
  end

  test "status returns error for non-started provider" do
    assert {:error, :not_started} = ProviderGate.status("nonexistent-provider")
  end

  test "successful requests keep circuit closed" do
    provider_id = unique_provider_id()
    start_gate(provider_id)

    for _ <- 1..10 do
      {:ok, ref} = ProviderGate.checkout(provider_id)
      ProviderGate.checkin(provider_id, ref, :ok)
    end

    {:ok, status} = ProviderGate.status(provider_id)
    assert status.circuit_state == :closed
  end

  test "mixed results below threshold keep circuit closed" do
    provider_id = unique_provider_id()
    start_gate(provider_id)

    # 2 errors out of 10 = 20% < 50% threshold
    # Use :non_retryable to avoid setting retry_after
    for i <- 1..10 do
      {:ok, ref} = ProviderGate.checkout(provider_id)

      result =
        if i <= 2, do: {:error, :non_retryable}, else: :ok

      ProviderGate.checkin(provider_id, ref, result)
    end

    {:ok, status} = ProviderGate.status(provider_id)
    assert status.circuit_state == :closed
  end

  test "circuit open checkout before cooldown returns error" do
    provider_id = unique_provider_id()
    _pid = start_gate(provider_id)

    # Trip the circuit — checkout all first, then checkin all
    refs =
      for _ <- 1..6 do
        {:ok, ref} = ProviderGate.checkout(provider_id)
        ref
      end

    for ref <- refs do
      ProviderGate.checkin(provider_id, ref, {:error, :non_retryable})
    end

    {:ok, status} = ProviderGate.status(provider_id)
    assert status.circuit_state == :open

    # Checkout while circuit is open and cooldown has NOT expired
    assert {:error, :circuit_open, remaining} = ProviderGate.checkout(provider_id)
    assert remaining > 0
  end

  test "handle_info ignores unexpected messages" do
    provider_id = unique_provider_id()
    pid = start_gate(provider_id)

    send(pid, :unexpected_message)
    # GenServer should still be alive and functional
    assert {:ok, _ref} = ProviderGate.checkout(provider_id)
  end

  test "checkout auto-starts gate via DynamicSupervisor" do
    provider_id = unique_provider_id()
    # Don't start_gate — let ensure_started handle it via DynamicSupervisor
    assert {:ok, ref} = ProviderGate.checkout(provider_id)
    assert is_reference(ref)

    :ok = ProviderGate.checkin(provider_id, ref, :ok)
  end

  test "non_retryable checkin does not extend retry_after" do
    provider_id = unique_provider_id()
    start_gate(provider_id)

    {:ok, status_before} = ProviderGate.status(provider_id)
    initial_retry_after = status_before.retry_after_until

    {:ok, ref} = ProviderGate.checkout(provider_id)
    ProviderGate.checkin(provider_id, ref, {:error, :non_retryable})

    {:ok, status_after} = ProviderGate.status(provider_id)
    # retry_after_until should not have been extended
    assert status_after.retry_after_until == initial_retry_after
  end

  describe "prune_window" do
    test "prunes old entries from error window" do
      provider_id = unique_provider_id()
      start_gate(provider_id)

      # Inject old timestamps into the error window to simulate aged-out entries
      :sys.replace_state(
        {:via, Registry, {Liteskill.LlmGateway.GateRegistry, provider_id}},
        fn state ->
          old_ts = System.monotonic_time(:millisecond) - 120_000
          old_entries = :queue.from_list([{old_ts, true}, {old_ts, false}])
          %{state | error_window: old_entries}
        end
      )

      # Perform a checkout + checkin which triggers record_result -> prune_window
      {:ok, ref} = ProviderGate.checkout(provider_id)
      ProviderGate.checkin(provider_id, ref, :ok)

      # Verify the old entries were pruned (1 remains from the checkin itself)
      {:ok, status} = ProviderGate.status(provider_id)
      assert status.error_count == 1
    end
  end
end
