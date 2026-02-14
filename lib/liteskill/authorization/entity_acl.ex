defmodule Liteskill.Authorization.EntityAcl do
  @moduledoc """
  Schema for centralized entity access control entries.

  Supports any entity type (conversation, report, source, mcp_server)
  with user-based or group-based access at three levels: owner, manager, viewer.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "entity_acls" do
    field :entity_type, :string
    field :entity_id, :binary_id
    field :role, :string, default: "viewer"

    belongs_to :user, Liteskill.Accounts.User
    belongs_to :group, Liteskill.Groups.Group

    timestamps(type: :utc_datetime)
  end

  @valid_entity_types [
    "agent_definition",
    "conversation",
    "instance",
    "llm_model",
    "llm_provider",
    "mcp_server",
    "report",
    "schedule",
    "source",
    "team_definition",
    "wiki_space"
  ]
  @valid_roles ["owner", "manager", "editor", "viewer"]

  def changeset(acl, attrs) do
    acl
    |> cast(attrs, [:entity_type, :entity_id, :user_id, :group_id, :role])
    |> validate_required([:entity_type, :entity_id, :role])
    |> validate_inclusion(:entity_type, @valid_entity_types)
    |> validate_inclusion(:role, @valid_roles)
    |> validate_user_or_group()
    |> unique_constraint([:entity_type, :entity_id, :user_id],
      name: :entity_acls_entity_user_idx
    )
    |> unique_constraint([:entity_type, :entity_id, :group_id],
      name: :entity_acls_entity_group_idx
    )
    |> check_constraint(:user_id, name: :entity_acl_user_or_group)
    |> foreign_key_constraint(:user_id)
  end

  defp validate_user_or_group(changeset) do
    user_id = get_field(changeset, :user_id)
    group_id = get_field(changeset, :group_id)

    cond do
      is_nil(user_id) and is_nil(group_id) ->
        add_error(changeset, :user_id, "either user_id or group_id must be set")

      not is_nil(user_id) and not is_nil(group_id) ->
        add_error(changeset, :user_id, "only one of user_id or group_id can be set")

      true ->
        changeset
    end
  end
end
