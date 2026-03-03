defmodule Liteskill.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :email, :string, null: false
      add :name, :string
      add :avatar_url, :string
      add :oidc_sub, :string, null: false
      add :oidc_issuer, :string, null: false
      add :oidc_claims, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:oidc_sub, :oidc_issuer])
    create unique_index(:users, [:email])
  end
end
