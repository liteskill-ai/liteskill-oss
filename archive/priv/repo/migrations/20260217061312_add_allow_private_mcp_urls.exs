defmodule Liteskill.Repo.Migrations.AddAllowPrivateMcpUrls do
  use Ecto.Migration

  def change do
    alter table(:server_settings) do
      add :allow_private_mcp_urls, :boolean, null: false, default: false
    end
  end
end
