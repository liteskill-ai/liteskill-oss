defmodule Liteskill.Repo.Migrations.CreateAgentStudioTables do
  use Ecto.Migration

  def change do
    # --- Agent Definitions ---
    create table(:agent_definitions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :text
      add :backstory, :text
      add :opinions, :map, default: %{}
      add :system_prompt, :text
      add :strategy, :string, null: false, default: "react"
      add :config, :map, default: %{}
      add :status, :string, null: false, default: "active"

      add :llm_model_id, references(:llm_models, type: :binary_id, on_delete: :nilify_all)
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:agent_definitions, [:user_id])
    create unique_index(:agent_definitions, [:name, :user_id])

    # --- Agent ↔ Tool (MCP Server) assignments ---
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

    # --- Team Definitions ---
    create table(:team_definitions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :text
      add :shared_context, :text
      add :default_topology, :string, null: false, default: "pipeline"
      add :aggregation_strategy, :string, null: false, default: "last"
      add :config, :map, default: %{}
      add :status, :string, null: false, default: "active"

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:team_definitions, [:user_id])
    create unique_index(:team_definitions, [:name, :user_id])

    # --- Team Members (agent roster) ---
    create table(:team_members, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :role, :string, null: false, default: "worker"
      add :description, :text
      add :position, :integer, null: false, default: 0

      add :team_definition_id,
          references(:team_definitions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :agent_definition_id,
          references(:agent_definitions, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime)
    end

    create index(:team_members, [:team_definition_id])
    create index(:team_members, [:agent_definition_id])

    create unique_index(:team_members, [:team_definition_id, :agent_definition_id],
             name: :team_members_unique_idx
           )

    # --- Instances (runtime task executions) ---
    create table(:instances, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :text
      add :prompt, :text, null: false
      add :topology, :string, null: false, default: "pipeline"
      add :status, :string, null: false, default: "pending"
      add :context, :map, default: %{}
      add :deliverables, :map, default: %{}
      add :error, :text
      add :timeout_ms, :integer, default: 1_800_000
      add :max_iterations, :integer, default: 50
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime

      add :team_definition_id,
          references(:team_definitions, type: :binary_id, on_delete: :nilify_all)

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:instances, [:user_id])
    create index(:instances, [:team_definition_id])
    create index(:instances, [:status])

    # --- Instance Tasks (steps within an instance) ---
    create table(:instance_tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :text
      add :status, :string, null: false, default: "pending"
      add :position, :integer, null: false, default: 0
      add :input_summary, :text
      add :output_summary, :text
      add :error, :text
      add :duration_ms, :integer
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime

      add :instance_id, references(:instances, type: :binary_id, on_delete: :delete_all),
        null: false

      add :agent_definition_id,
          references(:agent_definitions, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:instance_tasks, [:instance_id])
    create index(:instance_tasks, [:agent_definition_id])

    # --- Schedules (cron-like instance scheduling) ---
    create table(:schedules, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :text
      add :cron_expression, :string, null: false
      add :timezone, :string, null: false, default: "UTC"
      add :enabled, :boolean, null: false, default: true
      add :status, :string, null: false, default: "active"

      # Instance template fields (used to create instances on each run)
      add :prompt, :text, null: false
      add :topology, :string, null: false, default: "pipeline"
      add :context, :map, default: %{}
      add :timeout_ms, :integer, default: 1_800_000
      add :max_iterations, :integer, default: 50

      add :last_run_at, :utc_datetime
      add :next_run_at, :utc_datetime

      add :team_definition_id,
          references(:team_definitions, type: :binary_id, on_delete: :nilify_all)

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:schedules, [:user_id])
    create index(:schedules, [:team_definition_id])
    create index(:schedules, [:enabled, :next_run_at])
    create unique_index(:schedules, [:name, :user_id])
  end
end
