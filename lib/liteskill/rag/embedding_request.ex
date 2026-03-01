defmodule Liteskill.Rag.EmbeddingRequest do
  @moduledoc """
  Schema for tracking RAG embedding and rerank API requests.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "rag_embedding_requests" do
    field :request_type, :string
    field :status, :string
    field :latency_ms, :integer
    field :input_count, :integer
    field :token_count, :integer
    field :model_id, :string
    field :error_message, :string

    belongs_to :user, Liteskill.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @required_fields [:request_type, :status, :user_id]
  @optional_fields [:latency_ms, :input_count, :token_count, :model_id, :error_message]

  def changeset(request, attrs) do
    request
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:request_type, ["embed", "rerank"])
    |> validate_inclusion(:status, ["success", "error"])
    |> foreign_key_constraint(:user_id)
  end
end
