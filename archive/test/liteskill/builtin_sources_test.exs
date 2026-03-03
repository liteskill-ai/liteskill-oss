defmodule Liteskill.BuiltinSourcesTest do
  use ExUnit.Case, async: true

  alias Liteskill.BuiltinSources

  describe "all/0" do
    test "returns registered modules" do
      modules = BuiltinSources.all()
      assert Liteskill.BuiltinSources.Wiki in modules
    end
  end

  describe "virtual_sources/0" do
    test "returns virtual source maps with all expected fields" do
      sources = BuiltinSources.virtual_sources()
      assert sources != []

      wiki = Enum.find(sources, &(&1.id == "builtin:wiki"))
      assert wiki
      assert wiki.name == "Wiki"
      assert wiki.description == "Collaborative wiki pages in markdown"
      assert wiki.icon == "hero-book-open-micro"
      assert wiki.source_type == "builtin"
      assert wiki.builtin == true
      assert wiki.user_id == nil
      assert wiki.inserted_at == nil
      assert wiki.updated_at == nil
    end
  end

  describe "find/1" do
    test "finds Wiki by builtin ID" do
      source = BuiltinSources.find("builtin:wiki")
      assert source
      assert source.id == "builtin:wiki"
      assert source.name == "Wiki"
    end

    test "returns nil for unknown builtin ID" do
      assert BuiltinSources.find("builtin:unknown") == nil
    end

    test "returns nil for non-builtin string" do
      assert BuiltinSources.find("some-uuid") == nil
    end
  end
end
