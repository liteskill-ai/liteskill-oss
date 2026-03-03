defmodule Liteskill.Repo.Migrations.AddPasswordAuthToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :password_hash, :string
    end

    # Allow password-only users (no OIDC)
    execute(
      "ALTER TABLE users ALTER COLUMN oidc_sub DROP NOT NULL",
      "ALTER TABLE users ALTER COLUMN oidc_sub SET NOT NULL"
    )

    execute(
      "ALTER TABLE users ALTER COLUMN oidc_issuer DROP NOT NULL",
      "ALTER TABLE users ALTER COLUMN oidc_issuer SET NOT NULL"
    )
  end
end
