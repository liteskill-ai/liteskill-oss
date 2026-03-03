defmodule Liteskill.Repo.Migrations.AddSamlAuthToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :saml_name_id, :string
      add :saml_issuer, :string
    end

    create unique_index(:users, [:saml_name_id, :saml_issuer],
             where: "saml_name_id IS NOT NULL AND saml_issuer IS NOT NULL"
           )
  end
end
