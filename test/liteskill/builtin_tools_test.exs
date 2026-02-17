defmodule Liteskill.BuiltinToolsTest do
  use ExUnit.Case, async: true

  alias Liteskill.BuiltinTools

  test "all/0 returns registered modules" do
    modules = BuiltinTools.all()
    assert Liteskill.BuiltinTools.Reports in modules
  end

  test "all_tools/0 returns flat tool list" do
    tools = BuiltinTools.all_tools()
    assert is_list(tools)
    assert tools != []

    first = hd(tools)
    assert Map.has_key?(first, :id)
    assert Map.has_key?(first, :server_id)
    assert Map.has_key?(first, :server_name)
    assert Map.has_key?(first, :name)
    assert String.starts_with?(first.server_id, "builtin:")
  end

  test "virtual_servers/0 returns virtual server maps with all fields" do
    servers = BuiltinTools.virtual_servers()
    assert servers != []

    server = hd(servers)
    assert server.id == "builtin:reports"
    assert server.name == "Reports"
    assert server.builtin == Liteskill.BuiltinTools.Reports
    assert server.status == "active"
    assert server.global == true
    assert server.user_id == nil
    assert server.url == nil
  end

  test "find_handler/1 finds correct module" do
    assert BuiltinTools.find_handler("reports__create") == Liteskill.BuiltinTools.Reports
    assert BuiltinTools.find_handler("reports__list") == Liteskill.BuiltinTools.Reports
  end

  test "find_handler/1 returns nil for unknown tool" do
    assert BuiltinTools.find_handler("unknown_tool") == nil
  end
end
