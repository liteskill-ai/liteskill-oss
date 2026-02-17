defmodule Liteskill.EventStore do
  use Boundary, top_level?: true, deps: [], exports: [Event, Snapshot, Postgres]

  @moduledoc """
  Behaviour for event store implementations.

  Provides append-only event storage with optimistic concurrency control,
  stream reading, subscriptions via PubSub, and snapshot support.
  """

  alias Liteskill.EventStore.Event

  @type stream_id :: String.t()
  @type expected_version :: non_neg_integer()

  @callback append_events(stream_id(), expected_version(), [map()]) ::
              {:ok, [Event.t()]} | {:error, :wrong_expected_version}

  @callback read_stream_forward(stream_id()) :: [Event.t()]

  @callback read_stream_forward(stream_id(), non_neg_integer(), non_neg_integer()) :: [Event.t()]

  @callback stream_version(stream_id()) :: non_neg_integer()

  @callback subscribe(stream_id()) :: :ok

  @callback save_snapshot(stream_id(), non_neg_integer(), String.t(), map()) :: {:ok, any()}

  @callback get_latest_snapshot(stream_id()) :: {:ok, any()} | {:error, :not_found}
end
