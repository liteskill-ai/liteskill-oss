defmodule Liteskill.Release do
  @moduledoc """
  Release tasks for running migrations in production.

  Usage from a release:

      bin/liteskill eval "Liteskill.Release.migrate()"
      bin/liteskill eval "Liteskill.Release.rollback(Liteskill.Repo, 20240101000000)"
  """

  @app :liteskill

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.load(@app)
  end
end
