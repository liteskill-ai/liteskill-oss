defmodule Liteskill.Usage.UsageRecord do
  @moduledoc """
  Schema for LLM usage records.

  Each record tracks token usage and costs for a single LLM API call,
  keyed by user, conversation, and model for aggregation queries.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "llm_usage_records" do
    field :message_id, :binary_id
    field :model_id, :string
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :total_tokens, :integer, default: 0
    field :reasoning_tokens, :integer, default: 0
    field :cached_tokens, :integer, default: 0
    field :cache_creation_tokens, :integer, default: 0
    field :input_cost, :decimal
    field :output_cost, :decimal
    field :reasoning_cost, :decimal
    field :total_cost, :decimal
    field :latency_ms, :integer
    field :call_type, :string
    field :tool_round, :integer, default: 0

    belongs_to :user, Liteskill.Accounts.User
    belongs_to :conversation, Liteskill.Chat.Conversation
    belongs_to :llm_model, Liteskill.LlmModels.LlmModel
    belongs_to :run, Liteskill.Runs.Run

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :user_id,
      :conversation_id,
      :message_id,
      :model_id,
      :llm_model_id,
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :reasoning_tokens,
      :cached_tokens,
      :cache_creation_tokens,
      :input_cost,
      :output_cost,
      :reasoning_cost,
      :total_cost,
      :latency_ms,
      :call_type,
      :tool_round,
      :run_id
    ])
    |> validate_required([:user_id, :model_id, :call_type])
    |> validate_inclusion(:call_type, ["stream", "complete"])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:llm_model_id)
    |> foreign_key_constraint(:run_id)
  end
end
