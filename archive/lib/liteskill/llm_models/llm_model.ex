defmodule Liteskill.LlmModels.LlmModel do
  @moduledoc """
  Schema for configured LLM models.

  Each record represents a specific model available through a provider,
  accessible to users via instance-wide flag or entity ACLs.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_model_types ~w(inference embedding rerank)

  schema "llm_models" do
    field :name, :string
    field :model_id, :string
    field :model_type, :string, default: "inference"
    field :model_config, Liteskill.Crypto.EncryptedMap, default: %{}
    field :instance_wide, :boolean, default: false
    field :status, :string, default: "active"
    field :input_cost_per_million, :decimal
    field :output_cost_per_million, :decimal
    field :context_window, :integer
    field :max_output_tokens, :integer

    belongs_to :provider, Liteskill.LlmProviders.LlmProvider
    belongs_to :user, Liteskill.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def valid_model_types, do: @valid_model_types

  def changeset(model, attrs) do
    model
    |> cast(attrs, [
      :name,
      :model_id,
      :model_type,
      :model_config,
      :instance_wide,
      :status,
      :input_cost_per_million,
      :output_cost_per_million,
      :context_window,
      :max_output_tokens,
      :provider_id,
      :user_id
    ])
    |> validate_required([:name, :model_id, :provider_id, :user_id])
    |> validate_inclusion(:model_type, @valid_model_types)
    |> validate_inclusion(:status, ["active", "inactive"])
    |> validate_number(:context_window, greater_than: 0)
    |> validate_number(:max_output_tokens, greater_than: 0)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:provider_id)
    |> unique_constraint([:provider_id, :model_id])
  end
end
