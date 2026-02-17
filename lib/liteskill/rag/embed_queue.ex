defmodule Liteskill.Rag.EmbedQueue do
  @moduledoc """
  GenServer that batches embedding requests to Cohere's embed API.

  Implements a "train station" pattern: callers submit texts via `embed/2` and
  block until the batch fires. A batch fires either when:

  - The accumulated text count reaches `batch_size` (96, Cohere's per-request limit), or
  - A `flush_ms` timer (default 2 seconds) elapses with no new arrivals.

  On 429 rate-limit errors, retries with exponential backoff before returning
  the error to callers.
  """

  use GenServer

  alias Liteskill.Rag.EmbeddingClient

  @default_batch_size 96
  @default_flush_ms 2_000
  @default_max_retries 5
  @default_backoff_ms 1_000
  @max_backoff_ms 30_000

  # --- Public API ---

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Embed a list of texts, batched with other concurrent callers.

  Accepts the same opts as `EmbeddingClient.embed/2` plus:
  - `:name` — the GenServer to call (default `__MODULE__`)

  Returns `{:ok, embeddings}` or `{:error, reason}`.
  """
  def embed(texts, opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    if Process.whereis(name) do
      GenServer.call(name, {:embed, texts, opts}, :infinity)
    else
      # Fallback: call EmbeddingClient directly (e.g., in test env without GenServer)
      EmbeddingClient.embed(texts, opts)
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    config = Application.get_env(:liteskill, __MODULE__, [])

    state = %{
      queue: [],
      timer_ref: nil,
      batch_size: opts[:batch_size] || config[:batch_size] || @default_batch_size,
      flush_ms: opts[:flush_ms] || config[:flush_ms] || @default_flush_ms,
      max_retries: opts[:max_retries] || config[:max_retries] || @default_max_retries,
      backoff_ms: opts[:backoff_ms] || config[:backoff_ms] || @default_backoff_ms
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:embed, texts, opts}, from, state) do
    new_queue = state.queue ++ [{texts, from, opts}]
    total_texts = Enum.sum(Enum.map(new_queue, fn {t, _, _} -> length(t) end))

    if total_texts >= state.batch_size do
      cancel_timer(state.timer_ref)
      flush_batch(%{state | queue: new_queue, timer_ref: nil})
    else
      timer_ref = state.timer_ref || Process.send_after(self(), :flush, state.flush_ms)
      {:noreply, %{state | queue: new_queue, timer_ref: timer_ref}}
    end
  end

  @impl true
  def handle_info(:flush, state) do
    flush_batch(%{state | timer_ref: nil})
  end

  # --- Private ---

  # coveralls-ignore-next-line
  defp flush_batch(%{queue: []} = state), do: {:noreply, state}

  defp flush_batch(state) do
    all_texts = Enum.flat_map(state.queue, fn {texts, _, _} -> texts end)
    # Use opts from first entry; extract plug opts for CohereClient
    {_, _, first_opts} = hd(state.queue)
    {plug_opts, embed_opts} = Keyword.split(first_opts, [:plug])

    result =
      embed_with_retry(
        all_texts,
        embed_opts ++ plug_opts,
        state.max_retries,
        state.backoff_ms
      )

    # Reply to each caller with their slice of embeddings
    case result do
      {:ok, all_embeddings} ->
        reply_with_slices(state.queue, all_embeddings)

      {:error, reason} ->
        Enum.each(state.queue, fn {_, from, _} ->
          GenServer.reply(from, {:error, reason})
        end)
    end

    {:noreply, %{state | queue: [], timer_ref: nil}}
  end

  defp reply_with_slices(queue, all_embeddings) do
    {_, _} =
      Enum.reduce(queue, {0, all_embeddings}, fn {texts, from, _}, {offset, embs} ->
        count = length(texts)
        caller_embeddings = Enum.slice(embs, offset, count)
        GenServer.reply(from, {:ok, caller_embeddings})
        {offset + count, embs}
      end)

    :ok
  end

  defp embed_with_retry(texts, opts, retries_left, backoff_ms) do
    case EmbeddingClient.embed(texts, opts) do
      {:ok, _} = success ->
        success

      {:error, %{status: status}} when status in [429, 503] and retries_left > 0 ->
        Process.sleep(backoff_ms)
        next_backoff = min(backoff_ms * 2, @max_backoff_ms)
        embed_with_retry(texts, opts, retries_left - 1, next_backoff)

      {:error, _} = error ->
        error
    end
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(ref) do
    Process.cancel_timer(ref)
    # Flush any :flush message that may already be in the mailbox
    receive do
      # coveralls-ignore-next-line
      :flush -> :ok
    after
      0 -> :ok
    end
  end
end
