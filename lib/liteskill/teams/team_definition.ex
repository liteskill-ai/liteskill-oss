defmodule Liteskill.Teams.TeamDefinition do
  @moduledoc """
  Schema for team definitions — named collections of agents with shared context.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_topologies ~w(pipeline parallel debate hierarchical round_robin)
  @valid_aggregations ~w(last merge vote)
  @valid_statuses ~w(active inactive)

  schema "team_definitions" do
    field :name, :string
    field :description, :string
    field :shared_context, :string
    field :default_topology, :string, default: "pipeline"
    field :aggregation_strategy, :string, default: "last"
    field :config, :map, default: %{}
    field :status, :string, default: "active"

    belongs_to :user, Liteskill.Accounts.User
    has_many :team_members, Liteskill.Teams.TeamMember, preload_order: [asc: :position]

    timestamps(type: :utc_datetime)
  end

  def valid_topologies, do: @valid_topologies
  def valid_aggregations, do: @valid_aggregations

  def changeset(team, attrs) do
    team
    |> cast(attrs, [
      :name,
      :description,
      :shared_context,
      :default_topology,
      :aggregation_strategy,
      :config,
      :status,
      :user_id
    ])
    |> validate_required([:name, :user_id])
    |> validate_inclusion(:default_topology, @valid_topologies)
    |> validate_inclusion(:aggregation_strategy, @valid_aggregations)
    |> validate_inclusion(:status, @valid_statuses)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:name, :user_id])
  end
end
