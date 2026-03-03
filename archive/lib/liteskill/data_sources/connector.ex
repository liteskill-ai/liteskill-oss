defmodule Liteskill.DataSources.Connector do
  @moduledoc """
  Behaviour for data source connectors.

  Each external source type (github, google_drive, etc.) implements this
  behaviour. The sync pipeline calls these callbacks generically.
  """

  @type source :: Liteskill.DataSources.Source.t()
  @type cursor :: map() | nil

  @type file_entry :: %{
          external_id: String.t(),
          title: String.t(),
          content_type: String.t(),
          metadata: map(),
          parent_external_id: String.t() | nil,
          content_hash: String.t() | nil,
          deleted: boolean()
        }

  @type fetch_result :: %{
          content: String.t(),
          content_type: String.t(),
          content_hash: String.t(),
          metadata: map()
        }

  @type list_result :: %{
          entries: [file_entry()],
          next_cursor: cursor(),
          has_more: boolean()
        }

  @doc """
  List files/entries from the source since the given cursor.
  First sync: cursor is nil. Subsequent syncs: cursor is from previous sync.
  """
  @callback list_entries(source(), cursor(), keyword()) ::
              {:ok, list_result()} | {:error, term()}

  @doc """
  Fetch the content of a single entry by its external_id.
  Called only for entries whose content_hash has changed.
  """
  @callback fetch_content(source(), String.t(), keyword()) ::
              {:ok, fetch_result()} | {:error, term()}

  @doc """
  Validate that the source's credentials and connection work.
  """
  @callback validate_connection(source(), keyword()) :: :ok | {:error, term()}

  @doc """
  Returns the source_type string this connector handles.
  """
  @callback source_type() :: String.t()
end
