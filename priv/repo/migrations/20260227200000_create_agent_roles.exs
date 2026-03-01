defmodule Liteskill.Repo.Migrations.CreateAgentRoles do
  use Ecto.Migration

  def change do
    create table(:agent_roles, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :agent_definition_id,
          references(:agent_definitions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :role_id, references(:roles, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:agent_roles, [:agent_definition_id, :role_id])
    create index(:agent_roles, [:role_id])
  end
end
