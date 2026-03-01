defmodule Liteskill.Rag.EmbedQueue do
  @moduledoc """
  GenServer that batches embedding requests to Cohere's embed API.

  Implements a "train station" pattern: callers submit texts via `embed/2` and
  block until the batch fires. A batch fires either when:

  - The accumulated text count reaches `batch_size` (96, Cohere's per-request limit), or
  - A `flush_ms` timer (default 2 seconds) elapses with no new arrivals.

  On 429/503 errors, retries with exponential backoff using `Process.send_after`
  so the GenServer remains responsive to new requests during backoff.
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
      retry: nil,
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

    # Don't flush while a retry is in progress — queue up and wait
    if state.retry == nil do
      if total_texts >= state.batch_size do
        cancel_timer(state.timer_ref)
        flush_batch(%{state | queue: new_queue, timer_ref: nil})
      else
        timer_ref = state.timer_ref || Process.send_after(self(), :flush, state.flush_ms)
        {:noreply, %{state | queue: new_queue, timer_ref: timer_ref}}
      end
    else
      cancel_timer(state.timer_ref)
      {:noreply, %{state | queue: new_queue, timer_ref: nil}}
    end
  end

  @impl true
  def handle_info(:flush, state) do
    # coveralls-ignore-start — defensive: cancel_timer flushes the mailbox,
    # so a stale :flush should never arrive during retry
    if state.retry == nil do
      # coveralls-ignore-stop
      flush_batch(%{state | timer_ref: nil})
    else
      {:noreply, %{state | timer_ref: nil}}
    end
  end

  def handle_info(:retry_embed, state) do
    case state.retry do
      # coveralls-ignore-start — defensive: retry_embed should never fire with nil retry
      nil ->
        {:noreply, state}

      # coveralls-ignore-stop

      retry ->
        case EmbeddingClient.embed(retry.texts, retry.opts) do
          {:ok, _} = success ->
            reply_to_callers(retry.callers, success)
            maybe_schedule_flush(%{state | retry: nil})

          {:error, %{status: status}} when status in [429, 503] and retry.retries_left > 0 ->
            next_backoff = min(retry.backoff_ms * 2, @max_backoff_ms)

            new_retry = %{
              retry
              | retries_left: retry.retries_left - 1,
                backoff_ms: next_backoff
            }

            Process.send_after(self(), :retry_embed, retry.backoff_ms)
            {:noreply, %{state | retry: new_retry}}

          {:error, _} = error ->
            reply_to_callers(retry.callers, error)
            maybe_schedule_flush(%{state | retry: nil})
        end
    end
  end

  # --- Private ---

  # coveralls-ignore-next-line
  defp flush_batch(%{queue: []} = state), do: {:noreply, state}

  defp flush_batch(state) do
    all_texts = Enum.flat_map(state.queue, fn {texts, _, _} -> texts end)
    # Use opts from first entry; extract plug opts for CohereClient
    {_, _, first_opts} = hd(state.queue)
    {plug_opts, embed_opts} = Keyword.split(first_opts, [:plug])
    opts = embed_opts ++ plug_opts

    case EmbeddingClient.embed(all_texts, opts) do
      {:ok, all_embeddings} ->
        reply_with_slices(state.queue, all_embeddings)
        {:noreply, %{state | queue: [], timer_ref: nil}}

      {:error, %{status: status}} when status in [429, 503] and state.max_retries > 0 ->
        retry = %{
          texts: all_texts,
          callers: state.queue,
          opts: opts,
          retries_left: state.max_retries - 1,
          backoff_ms: min(state.backoff_ms * 2, @max_backoff_ms)
        }

        Process.send_after(self(), :retry_embed, state.backoff_ms)
        {:noreply, %{state | queue: [], retry: retry, timer_ref: nil}}

      {:error, reason} ->
        Enum.each(state.queue, fn {_, from, _} ->
          GenServer.reply(from, {:error, reason})
        end)

        {:noreply, %{state | queue: [], timer_ref: nil}}
    end
  end

  defp reply_to_callers(callers, {:ok, all_embeddings}) do
    reply_with_slices(callers, all_embeddings)
  end

  defp reply_to_callers(callers, {:error, reason}) do
    Enum.each(callers, fn {_, from, _} ->
      GenServer.reply(from, {:error, reason})
    end)
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

  defp maybe_schedule_flush(state) do
    # Schedule an immediate flush for the pending queue
    if state.queue == [] do
      {:noreply, state}
    else
      cancel_timer(state.timer_ref)
      timer_ref = Process.send_after(self(), :flush, 0)
      {:noreply, %{state | timer_ref: timer_ref}}
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
