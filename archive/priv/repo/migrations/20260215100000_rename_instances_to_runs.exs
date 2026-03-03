defmodule Liteskill.Repo.Migrations.RenameInstancesToRuns do
  use Ecto.Migration

  def up do
    # Rename tables
    rename table(:instances), to: table(:runs)
    rename table(:instance_tasks), to: table(:run_tasks)
    rename table(:instance_logs), to: table(:run_logs)

    # Rename FK columns
    rename table(:run_tasks), :instance_id, to: :run_id
    rename table(:run_logs), :instance_id, to: :run_id

    # Update ACL entity type
    execute "UPDATE entity_acls SET entity_type = 'run' WHERE entity_type = 'instance'"
  end

  def down do
    # Rename FK columns back
    rename table(:run_tasks), :run_id, to: :instance_id
    rename table(:run_logs), :run_id, to: :instance_id

    # Rename tables back
    rename table(:run_logs), to: table(:instance_logs)
    rename table(:run_tasks), to: table(:instance_tasks)
    rename table(:runs), to: table(:instances)

    # Revert ACL entity type
    execute "UPDATE entity_acls SET entity_type = 'instance' WHERE entity_type = 'run'"
  end
end
