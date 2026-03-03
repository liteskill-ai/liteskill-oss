defmodule Liteskill.DataSources.Connectors.Wiki do
  @moduledoc """
  Connector for the built-in Wiki source.

  Wiki is a local source — `list_entries` reads from the DB and
  `fetch_content` returns the stored content. Serves as the reference
  implementation for the Connector behaviour.
  """

  @behaviour Liteskill.DataSources.Connector

  alias Liteskill.DataSources

  @impl true
  def source_type, do: "wiki"

  @impl true
  def validate_connection(_source, _opts), do: :ok

  @impl true
  def list_entries(source, _cursor, opts) do
    user_id = Keyword.fetch!(opts, :user_id)
    documents = DataSources.list_documents(source.id, user_id)

    entries =
      Enum.map(documents, fn doc ->
        %{
          external_id: doc.id,
          title: doc.title,
          content_type: doc.content_type || "markdown",
          metadata: doc.metadata || %{},
          parent_external_id: doc.parent_document_id,
          content_hash: content_hash(doc.content),
          deleted: false
        }
      end)

    {:ok, %{entries: entries, next_cursor: nil, has_more: false}}
  end

  @impl true
  def fetch_content(_source, external_id, opts) do
    user_id = Keyword.fetch!(opts, :user_id)

    case DataSources.get_document(external_id, user_id) do
      {:ok, doc} ->
        {:ok,
         %{
           content: doc.content,
           content_type: doc.content_type || "markdown",
           content_hash: content_hash(doc.content),
           metadata: doc.metadata || %{}
         }}

      error ->
        error
    end
  end

  # coveralls-ignore-next-line
  defp content_hash(nil), do: nil
  defp content_hash(content), do: :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)
end
