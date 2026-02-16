defmodule Liteskill.Settings.ServerSettings do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @foreign_key_type :binary_id

  schema "server_settings" do
    field :registration_open, :boolean, default: true
    field :singleton, :boolean, default: true
    field :default_mcp_run_cost_limit, :decimal, default: Decimal.new("1.0")

    belongs_to :embedding_model, Liteskill.LlmModels.LlmModel

    timestamps(type: :utc_datetime)
  end

  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [:registration_open, :embedding_model_id, :default_mcp_run_cost_limit])
    |> validate_required([:registration_open])
    |> unique_constraint(:singleton)
    |> foreign_key_constraint(:embedding_model_id)
  end
end
