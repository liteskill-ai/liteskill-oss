defmodule Liteskill.Groups.Group do
  @moduledoc """
  Schema for user groups.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "groups" do
    field :name, :string

    belongs_to :creator, Liteskill.Accounts.User, foreign_key: :created_by
    has_many :memberships, Liteskill.Groups.GroupMembership

    timestamps(type: :utc_datetime)
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [:name, :created_by])
    |> validate_required([:name, :created_by])
    |> foreign_key_constraint(:created_by)
  end
end
