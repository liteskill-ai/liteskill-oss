defmodule Liteskill.LlmProviders.LlmProvider do
  @moduledoc """
  Schema for LLM provider endpoint configurations.

  Each record represents a configured provider connection with credentials.
  Models reference a provider to inherit its endpoint and auth config.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_provider_types ReqLLM.Provider.Generated.ValidProviders.list()
                        |> Enum.map(&Atom.to_string/1)
                        |> Enum.sort()

  schema "llm_providers" do
    field :name, :string
    field :provider_type, :string
    field :api_key, Liteskill.Crypto.EncryptedField
    field :provider_config, Liteskill.Crypto.EncryptedMap, default: %{}
    field :instance_wide, :boolean, default: false
    field :status, :string, default: "active"

    belongs_to :user, Liteskill.Accounts.User
    has_many :llm_models, Liteskill.LlmModels.LlmModel, foreign_key: :provider_id

    timestamps(type: :utc_datetime)
  end

  def valid_provider_types, do: @valid_provider_types

  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [
      :name,
      :provider_type,
      :api_key,
      :provider_config,
      :instance_wide,
      :status,
      :user_id
    ])
    |> validate_required([:name, :provider_type, :user_id])
    |> validate_inclusion(:provider_type, @valid_provider_types)
    |> validate_inclusion(:status, ["active", "inactive"])
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:name, :user_id])
  end
end
