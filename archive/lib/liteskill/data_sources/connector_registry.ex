defmodule Liteskill.DataSources.ConnectorRegistry do
  @moduledoc """
  Maps source_type strings to connector modules.
  """

  @connectors %{
    "wiki" => Liteskill.DataSources.Connectors.Wiki,
    "google_drive" => Liteskill.DataSources.Connectors.GoogleDrive
  }

  @doc "Returns the connector module for a given source_type."
  @spec get(String.t()) :: {:ok, module()} | {:error, :unknown_connector}
  def get(source_type) do
    case Map.fetch(@connectors, source_type) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :unknown_connector}
    end
  end

  @doc "Returns all registered {source_type, module} pairs."
  @spec all() :: [{String.t(), module()}]
  def all, do: Map.to_list(@connectors)
end
