defmodule Liteskill.Repo.Migrations.EncryptDataSourceMetadata do
  use Ecto.Migration

  def up do
    # Add a temporary text column for encrypted data
    alter table(:data_sources) do
      add :metadata_encrypted, :text
    end

    flush()

    # Backfill: read existing jsonb, JSON-encode, encrypt, write to new column
    repo().query!(
      "SELECT id, metadata FROM data_sources WHERE metadata IS NOT NULL AND metadata::text != 'null' AND metadata::text != '{}'",
      []
    )
    |> then(fn %{rows: rows, columns: columns} ->
      id_idx = Enum.find_index(columns, &(&1 == "id"))
      meta_idx = Enum.find_index(columns, &(&1 == "metadata"))

      for row <- rows do
        id = Enum.at(row, id_idx)
        metadata = Enum.at(row, meta_idx)

        json =
          case metadata do
            m when is_map(m) -> Jason.encode!(m)
            m when is_binary(m) -> m
          end

        encrypted = Liteskill.Crypto.encrypt(json)

        repo().query!(
          "UPDATE data_sources SET metadata_encrypted = $1 WHERE id = $2",
          [encrypted, id]
        )
      end
    end)

    # Drop old jsonb column and rename encrypted column
    alter table(:data_sources) do
      remove :metadata
    end

    rename table(:data_sources), :metadata_encrypted, to: :metadata
  end

  def down do
    # Add back the jsonb column
    alter table(:data_sources) do
      add :metadata_old, :map, default: %{}
    end

    flush()

    # Backfill: decrypt text back to jsonb
    repo().query!(
      "SELECT id, metadata FROM data_sources WHERE metadata IS NOT NULL",
      []
    )
    |> then(fn %{rows: rows, columns: columns} ->
      id_idx = Enum.find_index(columns, &(&1 == "id"))
      meta_idx = Enum.find_index(columns, &(&1 == "metadata"))

      for row <- rows do
        id = Enum.at(row, id_idx)
        encrypted = Enum.at(row, meta_idx)

        case Liteskill.Crypto.decrypt(encrypted) do
          plaintext when is_binary(plaintext) ->
            repo().query!(
              "UPDATE data_sources SET metadata_old = $1::jsonb WHERE id = $2",
              [plaintext, id]
            )

          _ ->
            :ok
        end
      end
    end)

    alter table(:data_sources) do
      remove :metadata
    end

    rename table(:data_sources), :metadata_old, to: :metadata
  end
end
