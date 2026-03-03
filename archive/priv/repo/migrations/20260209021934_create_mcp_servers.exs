defmodule Liteskill.Repo.Migrations.CreateMcpServers do
  use Ecto.Migration

  def change do
    create table(:mcp_servers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :url, :string, null: false
      add :api_key, :string
      add :description, :string
      add :headers, :map, default: %{}
      add :status, :string, null: false, default: "active"
      add :global, :boolean, null: false, default: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:mcp_servers, [:user_id])
  end
end
