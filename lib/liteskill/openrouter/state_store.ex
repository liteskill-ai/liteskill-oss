defmodule Liteskill.OpenRouter.StateStore do
  @moduledoc """
  ETS-backed store for pending OpenRouter OAuth PKCE flows.

  Used in desktop mode where the system browser can't share the Tauri
  webview's session cookies. Maps a random state token to the PKCE
  code_verifier, user_id, and return_to path with a 5-minute TTL.
  """

  use GenServer

  @table :openrouter_oauth_state
  @ttl_ms to_timeout(minute: 5)
  @cleanup_interval_ms to_timeout(minute: 1)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Generates a random state token and stores the PKCE flow data.

  Returns the state token string.
  """
  def store(code_verifier, user_id, return_to) do
    state = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    expires_at = System.monotonic_time(:millisecond) + @ttl_ms
    :ets.insert(@table, {state, code_verifier, user_id, return_to, expires_at})
    state
  end

  @doc """
  Atomically retrieves and deletes a state entry.

  Returns `{:ok, %{code_verifier: ..., user_id: ..., return_to: ...}}` or `:error`.
  """
  def fetch_and_delete(state_token) do
    case :ets.lookup(@table, state_token) do
      [{^state_token, verifier, user_id, return_to, expires_at}] ->
        :ets.delete(@table, state_token)
        now = System.monotonic_time(:millisecond)

        if now <= expires_at do
          {:ok, %{code_verifier: verifier, user_id: user_id, return_to: return_to}}
        else
          :error
        end

      [] ->
        :error
    end
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set])
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)

    :ets.select_delete(@table, [
      {{:_, :_, :_, :_, :"$1"}, [{:<, :"$1", now}], [true]}
    ])

    schedule_cleanup()
    {:noreply, state}
  end

  # coveralls-ignore-start — catch-all for unexpected messages
  def handle_info(_msg, state), do: {:noreply, state}
  # coveralls-ignore-stop

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
