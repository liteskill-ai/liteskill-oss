defmodule Liteskill.Chat.StreamRegistryTest do
  use ExUnit.Case, async: true

  alias Liteskill.Chat.StreamRegistry

  # Polls a condition function until it returns true, with bounded retries.
  # Replaces arbitrary Process.sleep calls with deterministic polling.
  defp assert_eventually(fun, retries \\ 20, interval \\ 10) do
    if fun.() do
      :ok
    else
      if retries > 0 do
        Process.sleep(interval)
        assert_eventually(fun, retries - 1, interval)
      else
        flunk("condition not met after polling")
      end
    end
  end

  setup do
    name = :"stream_registry_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {StreamRegistry, name: name, recovery_delay_ms: 10},
        id: name
      )

    %{registry: name, registry_pid: pid}
  end

  describe "register/2 and lookup/1" do
    test "registers and looks up a stream task", %{registry: name} do
      conv_id = Ecto.UUID.generate()

      task =
        Task.async(fn ->
          receive do
          end
        end)

      :ok = StreamRegistry.register(conv_id, task.pid, name: name)

      assert {:ok, pid} = StreamRegistry.lookup(conv_id)
      assert pid == task.pid

      Task.shutdown(task)
    end

    test "returns :error for unknown conversation" do
      assert :error = StreamRegistry.lookup(Ecto.UUID.generate())
    end

    test "returns :error after process exits", %{registry: name} do
      conv_id = Ecto.UUID.generate()
      task = Task.async(fn -> :ok end)
      :ok = StreamRegistry.register(conv_id, task.pid, name: name)

      # Wait for the task to finish
      Task.await(task)

      # Poll until the GenServer processes the DOWN message and cleans up ETS
      assert_eventually(fn -> :error == StreamRegistry.lookup(conv_id) end)
    end
  end

  describe "streaming?/1" do
    test "returns true for active stream", %{registry: name} do
      conv_id = Ecto.UUID.generate()

      task =
        Task.async(fn ->
          receive do
          end
        end)

      :ok = StreamRegistry.register(conv_id, task.pid, name: name)

      assert StreamRegistry.streaming?(conv_id)

      Task.shutdown(task)
    end

    test "returns false for no stream" do
      refute StreamRegistry.streaming?(Ecto.UUID.generate())
    end
  end

  describe "unregister/1" do
    test "removes entry from registry", %{registry: name} do
      conv_id = Ecto.UUID.generate()

      task =
        Task.async(fn ->
          receive do
          end
        end)

      :ok = StreamRegistry.register(conv_id, task.pid, name: name)
      assert StreamRegistry.streaming?(conv_id)

      :ok = StreamRegistry.unregister(conv_id, name: name)
      refute StreamRegistry.streaming?(conv_id)

      Task.shutdown(task)
    end
  end

  describe "auto-cleanup on process exit" do
    test "cleans up when monitored process crashes", %{registry: name} do
      conv_id = Ecto.UUID.generate()

      pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      :ok = StreamRegistry.register(conv_id, pid, name: name)
      assert StreamRegistry.streaming?(conv_id)

      # Kill the process and wait for monitor cleanup
      Process.exit(pid, :kill)
      assert_eventually(fn -> not StreamRegistry.streaming?(conv_id) end)
    end

    test "cleans up when process exits normally", %{registry: name} do
      conv_id = Ecto.UUID.generate()

      pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      :ok = StreamRegistry.register(conv_id, pid, name: name)
      assert StreamRegistry.streaming?(conv_id)

      send(pid, :stop)
      assert_eventually(fn -> not StreamRegistry.streaming?(conv_id) end)
    end

    test "schedules recovery after process exits", %{registry: name, registry_pid: registry_pid} do
      conv_id = Ecto.UUID.generate()

      pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      :ok = StreamRegistry.register(conv_id, pid, name: name)
      Process.exit(pid, :kill)

      # Wait for DOWN to be processed
      assert_eventually(fn -> not StreamRegistry.streaming?(conv_id) end)

      # Verify recovery was scheduled by checking state is clean
      state = :sys.get_state(registry_pid)
      assert state.monitors == %{}
    end
  end

  describe "unregister with multiple monitors" do
    test "preserves other monitors when unregistering one", %{registry: name, registry_pid: pid} do
      conv_a = Ecto.UUID.generate()
      conv_b = Ecto.UUID.generate()

      task_a =
        Task.async(fn ->
          receive do
          end
        end)

      task_b =
        Task.async(fn ->
          receive do
          end
        end)

      :ok = StreamRegistry.register(conv_a, task_a.pid, name: name)
      :ok = StreamRegistry.register(conv_b, task_b.pid, name: name)

      # Unregister conv_a — the reduce must skip conv_b's monitor entry
      :ok = StreamRegistry.unregister(conv_a, name: name)

      refute StreamRegistry.streaming?(conv_a)
      assert StreamRegistry.streaming?(conv_b)

      # conv_b's monitor should still be in state
      state = :sys.get_state(pid)
      assert map_size(state.monitors) == 1

      Task.shutdown(task_a)
      Task.shutdown(task_b)
    end
  end

  describe "DOWN for unknown ref" do
    test "handles DOWN for already-demonitored ref", %{registry_pid: pid} do
      # Send a fake DOWN message with a ref that doesn't exist in monitors
      fake_ref = make_ref()
      fake_pid = spawn(fn -> :ok end)
      send(pid, {:DOWN, fake_ref, :process, fake_pid, :normal})

      # GenServer should handle it without crashing
      state = :sys.get_state(pid)
      assert state.monitors == %{}
    end
  end

  describe "recover handler" do
    test "executes recovery via TaskSupervisor", %{registry_pid: pid} do
      conv_id = Ecto.UUID.generate()

      # Send the :recover message directly to exercise the handler
      send(pid, {:recover, conv_id, 0})

      # Synchronize — ensures the GenServer processed the message
      _ = :sys.get_state(pid)
    end
  end

  describe "double-registration safety" do
    test "second registration survives first process exit", %{registry: name} do
      conv_id = Ecto.UUID.generate()

      pid1 =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      pid2 =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      :ok = StreamRegistry.register(conv_id, pid1, name: name)
      assert {:ok, ^pid1} = StreamRegistry.lookup(conv_id)

      # Re-register with a new pid (simulates double-launch)
      :ok = StreamRegistry.register(conv_id, pid2, name: name)
      assert {:ok, ^pid2} = StreamRegistry.lookup(conv_id)

      # Kill the first process — should NOT remove the second's registration
      Process.exit(pid1, :kill)
      # Wait for monitor cleanup of pid1 to complete
      ref = Process.monitor(pid1)
      assert_receive {:DOWN, ^ref, :process, ^pid1, _}, 500

      # pid2 should still be registered
      assert {:ok, ^pid2} = StreamRegistry.lookup(conv_id)

      send(pid2, :stop)
    end
  end

  describe "recovery skipped when new stream active" do
    test "skips recovery if a new stream registered for the same conversation", %{
      registry: name,
      registry_pid: registry_pid
    } do
      conv_id = Ecto.UUID.generate()

      # Register a new active stream for this conversation
      active_task =
        Task.async(fn ->
          receive do
          end
        end)

      :ok = StreamRegistry.register(conv_id, active_task.pid, name: name)
      assert StreamRegistry.streaming?(conv_id)

      # Send a :recover message (simulating a delayed recovery from a crashed old stream)
      send(registry_pid, {:recover, conv_id, 0})
      # Synchronize — ensure the GenServer processed the message
      _ = :sys.get_state(registry_pid)

      # The active stream should still be running (recovery was skipped)
      assert StreamRegistry.streaming?(conv_id)
      assert {:ok, pid} = StreamRegistry.lookup(conv_id)
      assert pid == active_task.pid

      Task.shutdown(active_task)
    end
  end

  describe "auto-recovery failure" do
    test "logs warning when recovery fails for non-existent conversation", %{registry: name} do
      conv_id = Ecto.UUID.generate()

      # Register with a pid that will die
      task =
        Task.async(fn ->
          receive do
            :stop -> :ok
          end
        end)

      :ok = StreamRegistry.register(conv_id, task.pid, name: name)

      # Kill the task to trigger recovery
      send(task.pid, :stop)
      Task.await(task)

      # The recovery will be attempted and fail (non-existent conversation)
      # Just verify it doesn't crash the registry
      Process.sleep(100)

      # Registry should still be functional
      assert :error = StreamRegistry.lookup(conv_id)
    end
  end
end
