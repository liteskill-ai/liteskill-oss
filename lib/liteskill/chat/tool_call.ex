defmodule Liteskill.Chat.ToolCall do
  @moduledoc """
  Projection schema for tool calls within an assistant message.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "tool_calls" do
    field :tool_use_id, :string
    field :tool_name, :string
    field :input, :map
    field :output, :map
    field :status, :string, default: "started"
    field :duration_ms, :integer

    belongs_to :message, Liteskill.Chat.Message

    timestamps(type: :utc_datetime)
  end

  def changeset(tool_call, attrs) do
    tool_call
    |> cast(attrs, [:message_id, :tool_use_id, :tool_name, :input, :output, :status, :duration_ms])
    |> validate_required([:message_id, :tool_use_id, :tool_name])
    |> foreign_key_constraint(:message_id)
  end
end
