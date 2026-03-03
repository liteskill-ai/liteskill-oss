defmodule LiteskillWeb.Plugs.SessionHelpersTest do
  use ExUnit.Case, async: true

  alias LiteskillWeb.Plugs.SessionHelpers

  defp build_conn(headers \\ []) do
    conn = Plug.Test.conn(:get, "/")

    Enum.reduce(headers, conn, fn {key, value}, acc ->
      Plug.Conn.put_req_header(acc, key, value)
    end)
  end

  describe "client_ip/1" do
    test "returns remote_ip when no x-forwarded-for header" do
      conn = build_conn()
      assert SessionHelpers.client_ip(conn) == "127.0.0.1"
    end

    test "returns first IP from x-forwarded-for" do
      conn = build_conn([{"x-forwarded-for", "203.0.113.50"}])
      assert SessionHelpers.client_ip(conn) == "203.0.113.50"
    end

    test "returns first IP from comma-separated x-forwarded-for" do
      conn = build_conn([{"x-forwarded-for", "203.0.113.50, 70.41.3.18, 150.172.238.178"}])
      assert SessionHelpers.client_ip(conn) == "203.0.113.50"
    end

    test "trims whitespace from IP" do
      conn = build_conn([{"x-forwarded-for", "  10.0.0.1  , 192.168.1.1"}])
      assert SessionHelpers.client_ip(conn) == "10.0.0.1"
    end
  end

  describe "client_user_agent/1" do
    test "returns user-agent header value" do
      conn = build_conn([{"user-agent", "Mozilla/5.0"}])
      assert SessionHelpers.client_user_agent(conn) == "Mozilla/5.0"
    end

    test "returns nil when no user-agent header" do
      conn = build_conn()
      assert SessionHelpers.client_user_agent(conn) == nil
    end

    test "truncates user-agent to 512 characters" do
      long_ua = String.duplicate("A", 1000)
      conn = build_conn([{"user-agent", long_ua}])

      result = SessionHelpers.client_user_agent(conn)
      assert String.length(result) == 512
    end
  end

  describe "conn_info/1" do
    test "returns map with ip_address and user_agent" do
      conn = build_conn([{"user-agent", "TestAgent/1.0"}, {"x-forwarded-for", "10.0.0.1"}])

      assert %{ip_address: "10.0.0.1", user_agent: "TestAgent/1.0"} =
               SessionHelpers.conn_info(conn)
    end

    test "returns nil user_agent when header missing" do
      conn = build_conn()

      result = SessionHelpers.conn_info(conn)
      assert result.ip_address == "127.0.0.1"
      assert result.user_agent == nil
    end
  end
end
