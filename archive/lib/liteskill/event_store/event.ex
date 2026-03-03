defmodule Liteskill.EventStore.Event do
  @moduledoc """
  Ecto schema for the events table.

  Events are append-only and immutable. Each event belongs to a stream
  identified by `stream_id` and is versioned within that stream.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  @type t :: %__MODULE__{
          id: binary(),
          stream_id: String.t(),
          stream_version: integer(),
          event_type: String.t(),
          data: map(),
          metadata: map(),
          inserted_at: DateTime.t()
        }

  schema "events" do
    field :stream_id, :string
    field :stream_version, :integer
    field :event_type, :string
    field :data, :map
    field :metadata, :map, default: %{}
    field :inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []}
  end
end
