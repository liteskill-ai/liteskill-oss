defmodule Liteskill.Chat.Conversation do
  @moduledoc """
  Projection schema for conversations.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "conversations" do
    field :stream_id, :string
    field :title, :string
    field :model_id, :string
    field :system_prompt, :string
    field :status, :string, default: "active"
    field :fork_at_version, :integer
    field :message_count, :integer, default: 0
    field :last_message_at, :utc_datetime

    belongs_to :user, Liteskill.Accounts.User
    belongs_to :parent_conversation, __MODULE__
    belongs_to :llm_model, Liteskill.LlmModels.LlmModel
    has_many :messages, Liteskill.Chat.Message
    has_many :branches, __MODULE__, foreign_key: :parent_conversation_id

    timestamps(type: :utc_datetime)
  end

  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [
      :stream_id,
      :user_id,
      :title,
      :model_id,
      :system_prompt,
      :status,
      :parent_conversation_id,
      :fork_at_version,
      :message_count,
      :last_message_at,
      :llm_model_id
    ])
    |> validate_required([:stream_id, :user_id, :status])
    |> unique_constraint(:stream_id)
    |> foreign_key_constraint(:user_id)
  end
end
