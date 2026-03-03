defmodule Liteskill.EventStore.Snapshot do
  @moduledoc """
  Ecto schema for the snapshots table.

  Snapshots capture aggregate state at a given stream version to avoid
  replaying the entire event history on every load.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "snapshots" do
    field :stream_id, :string
    field :stream_version, :integer
    field :snapshot_type, :string
    field :data, :map
    field :inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []}
  end
end
