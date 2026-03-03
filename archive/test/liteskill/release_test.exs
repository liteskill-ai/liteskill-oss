defmodule Liteskill.ReleaseTest do
  use Liteskill.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Liteskill.Release

  describe "migrate/0" do
    test "runs migrations without error (no pending migrations)" do
      result = Release.migrate()
      assert is_list(result)
    end
  end

  describe "rollback/2" do
    test "rollback to a far-future version is a no-op" do
      # Use a version far in the future — no migrations match, so nothing runs.
      # This exercises load_app/0, repos/0, and the Migrator.with_repo path.
      Sandbox.checkout(Liteskill.Repo)
      Sandbox.mode(Liteskill.Repo, :auto)

      try do
        {:ok, _, _} = Release.rollback(Liteskill.Repo, 99_999_999_999_999)
      after
        Sandbox.mode(Liteskill.Repo, {:shared, self()})
      end
    end
  end
end
