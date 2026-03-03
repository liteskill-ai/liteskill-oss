defmodule Liteskill.OpenRouter.StateStoreTest do
  use ExUnit.Case, async: true

  alias Liteskill.OpenRouter.StateStore

  describe "store/3 and fetch_and_delete/1" do
    test "stores and retrieves a state entry" do
      state = StateStore.store("verifier123", "user-id-1", "/setup")

      assert is_binary(state)
      assert byte_size(state) > 0

      assert {:ok, data} = StateStore.fetch_and_delete(state)
      assert data.code_verifier == "verifier123"
      assert data.user_id == "user-id-1"
      assert data.return_to == "/setup"
    end

    test "deletes entry after fetch" do
      state = StateStore.store("verifier", "user-id", "/")

      assert {:ok, _} = StateStore.fetch_and_delete(state)
      assert :error = StateStore.fetch_and_delete(state)
    end

    test "returns :error for unknown state token" do
      assert :error = StateStore.fetch_and_delete("nonexistent")
    end

    test "generates unique state tokens" do
      s1 = StateStore.store("v1", "u1", "/")
      s2 = StateStore.store("v2", "u2", "/")

      assert s1 != s2
    end
  end

  describe "TTL expiry" do
    test "expired entries return :error" do
      # Insert directly into ETS with an already-expired timestamp
      expired_at = System.monotonic_time(:millisecond) - 1
      :ets.insert(:openrouter_oauth_state, {"expired-state", "v", "u", "/", expired_at})

      assert :error = StateStore.fetch_and_delete("expired-state")
    end
  end

  describe "cleanup" do
    test "cleanup message removes expired entries" do
      expired_at = System.monotonic_time(:millisecond) - 1
      :ets.insert(:openrouter_oauth_state, {"stale", "v", "u", "/", expired_at})

      # Trigger cleanup
      send(StateStore, :cleanup)
      # Give GenServer time to process
      _ = :sys.get_state(StateStore)

      assert :ets.lookup(:openrouter_oauth_state, "stale") == []
    end

    test "cleanup preserves non-expired entries" do
      state = StateStore.store("keeper", "uid", "/setup")

      send(StateStore, :cleanup)
      _ = :sys.get_state(StateStore)

      assert {:ok, _} = StateStore.fetch_and_delete(state)
    end
  end
end
