defmodule Liteskill.Repo.Migrations.AddAgentAclsAndDropAgentTools do
  use Ecto.Migration

  def up do
    # 1. Add agent_definition_id column to entity_acls
    alter table(:entity_acls) do
      add :agent_definition_id,
          references(:agent_definitions, type: :binary_id, on_delete: :delete_all)
    end

    create index(:entity_acls, [:agent_definition_id])

    # 2. Create unique index for (entity_type, entity_id, agent_definition_id)
    create unique_index(:entity_acls, [:entity_type, :entity_id, :agent_definition_id],
             where: "agent_definition_id IS NOT NULL",
             name: :entity_acls_entity_agent_idx
           )

    # 3. Drop old constraint and create new one (exactly one of three)
    drop constraint(:entity_acls, :entity_acl_user_or_group)

    create constraint(:entity_acls, :entity_acl_exactly_one_grantee,
             check: """
             (
               (user_id IS NOT NULL AND group_id IS NULL AND agent_definition_id IS NULL) OR
               (user_id IS NULL AND group_id IS NOT NULL AND agent_definition_id IS NULL) OR
               (user_id IS NULL AND group_id IS NULL AND agent_definition_id IS NOT NULL)
             )
             """
           )

    # 4. Migrate data: agent_tools -> entity_acls
    # For each unique (agent_definition_id, mcp_server_id), create a "viewer" ACL
    execute("""
    INSERT INTO entity_acls (id, entity_type, entity_id, agent_definition_id, role, inserted_at, updated_at)
    SELECT
      gen_random_uuid(),
      'mcp_server',
      at.mcp_server_id,
      at.agent_definition_id,
      'viewer',
      NOW(),
      NOW()
    FROM (
      SELECT DISTINCT agent_definition_id, mcp_server_id
      FROM agent_tools
    ) at
    ON CONFLICT DO NOTHING
    """)

    # 5. Migrate tool_name filters into agent_definitions.config
    execute("""
    UPDATE agent_definitions ad
    SET config = jsonb_set(
      COALESCE(ad.config, '{}')::jsonb,
      '{tool_filters}',
      (
        SELECT jsonb_object_agg(sub.mcp_server_id::text, sub.tool_names)
        FROM (
          SELECT at2.mcp_server_id, jsonb_agg(at2.tool_name) AS tool_names
          FROM agent_tools at2
          WHERE at2.agent_definition_id = ad.id
            AND at2.tool_name IS NOT NULL
          GROUP BY at2.mcp_server_id
        ) sub
      )
    )
    WHERE EXISTS (
      SELECT 1 FROM agent_tools at3
      WHERE at3.agent_definition_id = ad.id AND at3.tool_name IS NOT NULL
    )
    """)

    # 6. Drop the agent_tools table
    drop table(:agent_tools)
  end

  def down do
    # Recreate agent_tools
    create table(:agent_tools, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :agent_definition_id,
          references(:agent_definitions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :mcp_server_id,
          references(:mcp_servers, type: :binary_id, on_delete: :delete_all),
          null: false

      add :tool_name, :string

      timestamps(type: :utc_datetime)
    end

    create index(:agent_tools, [:agent_definition_id])
    create index(:agent_tools, [:mcp_server_id])

    create unique_index(:agent_tools, [:agent_definition_id, :mcp_server_id, :tool_name],
             name: :agent_tools_unique_idx
           )

    # Reverse data migration: entity_acls back to agent_tools
    execute("""
    INSERT INTO agent_tools (id, agent_definition_id, mcp_server_id, inserted_at, updated_at)
    SELECT gen_random_uuid(), agent_definition_id, entity_id, NOW(), NOW()
    FROM entity_acls
    WHERE entity_type = 'mcp_server' AND agent_definition_id IS NOT NULL
    """)

    # Drop the new constraint and agent_definition_id column
    drop constraint(:entity_acls, :entity_acl_exactly_one_grantee)

    drop_if_exists index(:entity_acls, [:agent_definition_id],
                     name: :entity_acls_entity_agent_idx
                   )

    alter table(:entity_acls) do
      remove :agent_definition_id
    end

    # Restore original constraint
    create constraint(:entity_acls, :entity_acl_user_or_group,
             check:
               "(user_id IS NOT NULL AND group_id IS NULL) OR (user_id IS NULL AND group_id IS NOT NULL)"
           )
  end
end
