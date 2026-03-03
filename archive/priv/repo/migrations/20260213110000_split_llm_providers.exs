defmodule Liteskill.Repo.Migrations.SplitLlmProviders do
  use Ecto.Migration

  def up do
    # 1. Create llm_providers table
    create table(:llm_providers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :provider_type, :string, null: false
      add :api_key, :text
      add :provider_config, :text
      add :instance_wide, :boolean, null: false, default: false
      add :status, :string, null: false, default: "active"
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:llm_providers, [:user_id])
    create unique_index(:llm_providers, [:name, :user_id])

    # 2. Add new columns to llm_models (nullable provider_id initially)
    alter table(:llm_models) do
      add :provider_id, references(:llm_providers, type: :binary_id, on_delete: :restrict)
      add :model_type, :string, null: false, default: "inference"
      add :model_config, :text
    end

    create index(:llm_models, [:provider_id])

    # 3. Data migration: create providers from existing models
    execute("""
    INSERT INTO llm_providers (id, name, provider_type, api_key, provider_config, instance_wide, status, user_id, inserted_at, updated_at)
    SELECT DISTINCT ON (m.provider, m.user_id)
      gen_random_uuid(),
      m.provider,
      m.provider,
      m.api_key,
      m.provider_config,
      m.instance_wide,
      'active',
      m.user_id,
      NOW(),
      NOW()
    FROM llm_models m
    """)

    # Create owner ACLs for migrated providers
    execute("""
    INSERT INTO entity_acls (id, entity_type, entity_id, user_id, role, inserted_at, updated_at)
    SELECT gen_random_uuid(), 'llm_provider', p.id, p.user_id, 'owner', NOW(), NOW()
    FROM llm_providers p
    ON CONFLICT DO NOTHING
    """)

    # Link models to their providers
    execute("""
    UPDATE llm_models m
    SET provider_id = p.id
    FROM llm_providers p
    WHERE p.provider_type = m.provider AND p.user_id = m.user_id
    """)

    # 4. Make provider_id NOT NULL
    alter table(:llm_models) do
      modify :provider_id, :binary_id, null: false, from: {:binary_id, null: true}
    end

    # 5. Drop old columns
    drop unique_index(:llm_models, [:provider, :model_id, :user_id])

    alter table(:llm_models) do
      remove :provider
      remove :api_key
      remove :provider_config
    end

    # 6. New unique index
    create unique_index(:llm_models, [:provider_id, :model_id])
  end

  def down do
    # Add back old columns
    alter table(:llm_models) do
      add :provider, :string
      add :api_key, :text
      add :provider_config, :text
    end

    # Restore data from providers
    execute("""
    UPDATE llm_models m
    SET provider = p.provider_type,
        api_key = p.api_key,
        provider_config = p.provider_config
    FROM llm_providers p
    WHERE p.id = m.provider_id
    """)

    alter table(:llm_models) do
      modify :provider, :string, null: false, from: {:string, null: true}
    end

    drop unique_index(:llm_models, [:provider_id, :model_id])

    alter table(:llm_models) do
      remove :provider_id
      remove :model_type
      remove :model_config
    end

    create unique_index(:llm_models, [:provider, :model_id, :user_id])

    # Clean up provider ACLs
    execute("DELETE FROM entity_acls WHERE entity_type = 'llm_provider'")

    drop table(:llm_providers)
  end
end
