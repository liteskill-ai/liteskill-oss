defmodule Liteskill.MapUtils do
  @moduledoc """
  Shared utilities for recursive key conversion between atom and string keys.

  Used by event serialization and aggregate snapshot persistence to ensure
  consistent JSONB round-tripping.
  """

  @doc """
  Recursively converts all map keys to strings.
  """
  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  @doc false
  def stringify_value(map) when is_map(map) and not is_struct(map), do: stringify_keys(map)
  def stringify_value(list) when is_list(list), do: Enum.map(list, &stringify_value/1)
  def stringify_value(value), do: value
end
