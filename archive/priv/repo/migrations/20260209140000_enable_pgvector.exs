defmodule Liteskill.Repo.Migrations.EnablePgvector do
  use Ecto.Migration

  def up, do: execute("CREATE EXTENSION IF NOT EXISTS vector")
  def down, do: execute("DROP EXTENSION IF EXISTS vector")
end
