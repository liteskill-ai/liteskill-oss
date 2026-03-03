defmodule LiteskillWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use LiteskillWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use LiteskillWeb, :verified_routes

      import LiteskillWeb.ConnCase
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import Plug.Conn
      # The default endpoint for testing
      @endpoint LiteskillWeb.Endpoint

      # Import conveniences for testing with connections
    end
  end

  @doc """
  Initializes a test session with a server-side session token for the given user.
  Use this instead of `init_test_session(%{user_id: user.id})`.
  Accepts optional extra session data to merge in.
  """
  def init_authenticated_session(conn, user, extra_session \\ %{}) do
    {:ok, session} = Liteskill.Accounts.create_session(user.id)
    session_data = Map.merge(%{session_token: session.id}, extra_session)

    Plug.Test.init_test_session(conn, session_data)
  end

  @doc """
  Convenience wrapper: builds a conn with an authenticated session for the given user.
  Works with both controller tests and `Phoenix.LiveViewTest.live/2`.
  """
  def log_in_user(conn, user) do
    init_authenticated_session(conn, user)
  end

  setup tags do
    Liteskill.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
