defmodule Liteskill.Authorization.EntityAcl do
  @moduledoc """
  Schema for centralized entity access control entries.

  Supports any entity type (conversation, report, source, mcp_server)
  with user-based, group-based, or agent-based access at four levels:
  owner, manager, editor, viewer.

  Exactly one of user_id, group_id, or agent_definition_id must be set.
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
    field :agent_definition_id, :binary_id

    timestamps(type: :utc_datetime)
  end

  @valid_entity_types [
    "agent_definition",
    "conversation",
    "run",
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
    |> cast(attrs, [:entity_type, :entity_id, :user_id, :group_id, :agent_definition_id, :role])
    |> validate_required([:entity_type, :entity_id, :role])
    |> validate_inclusion(:entity_type, @valid_entity_types)
    |> validate_inclusion(:role, @valid_roles)
    |> validate_exactly_one_grantee()
    |> unique_constraint([:entity_type, :entity_id, :user_id],
      name: :entity_acls_entity_user_idx
    )
    |> unique_constraint([:entity_type, :entity_id, :group_id],
      name: :entity_acls_entity_group_idx
    )
    |> unique_constraint([:entity_type, :entity_id, :agent_definition_id],
      name: :entity_acls_entity_agent_idx
    )
    |> check_constraint(:user_id, name: :entity_acl_exactly_one_grantee)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:group_id)
    |> foreign_key_constraint(:agent_definition_id)
  end

  defp validate_exactly_one_grantee(changeset) do
    user_id = get_field(changeset, :user_id)
    group_id = get_field(changeset, :group_id)
    agent_definition_id = get_field(changeset, :agent_definition_id)

    set_count = Enum.count([user_id, group_id, agent_definition_id], &(not is_nil(&1)))

    case set_count do
      1 ->
        changeset

      0 ->
        add_error(
          changeset,
          :user_id,
          "exactly one of user_id, group_id, or agent_definition_id must be set"
        )

      _ ->
        add_error(
          changeset,
          :user_id,
          "only one of user_id, group_id, or agent_definition_id can be set"
        )
    end
  end
end
