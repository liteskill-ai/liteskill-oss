defmodule Liteskill.BuiltinSources do
  use Boundary, top_level?: true, deps: [], exports: [Wiki]

  @moduledoc """
  Behaviour and registry for built-in data sources.

  Built-in sources are data sources that exist in code (no DB row),
  appearing alongside user-created DB sources in the sources listing.
  """

  @callback id() :: String.t()
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback icon() :: String.t()

  @registry [Liteskill.BuiltinSources.Wiki]

  def all, do: @registry

  @doc """
  Returns virtual source maps for all built-in sources.
  These can be shown alongside real DB sources in the UI.
  """
  def virtual_sources do
    Enum.map(@registry, fn mod ->
      %{
        id: "builtin:#{mod.id()}",
        name: mod.name(),
        description: mod.description(),
        icon: mod.icon(),
        source_type: "builtin",
        user_id: nil,
        builtin: true,
        inserted_at: nil,
        updated_at: nil
      }
    end)
  end

  @doc """
  Finds a built-in source by its full \"builtin:<id>\" string, or nil.
  """
  def find("builtin:" <> id) do
    Enum.find(virtual_sources(), fn vs -> vs.id == "builtin:#{id}" end)
  end

  def find(_), do: nil
end
