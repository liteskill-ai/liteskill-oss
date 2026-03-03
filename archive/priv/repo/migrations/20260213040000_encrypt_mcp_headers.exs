defmodule Liteskill.Repo.Migrations.EncryptMcpHeaders do
  use Ecto.Migration

  def up do
    # Change column from jsonb (map) to text for encrypted storage
    alter table(:mcp_servers) do
      modify :headers, :text
    end

    flush()

    # Encrypt existing plaintext JSON header values
    repo().query!(
      "SELECT id, headers FROM mcp_servers WHERE headers IS NOT NULL",
      []
    )
    |> Map.get(:rows, [])
    |> Enum.each(fn [id, headers_value] ->
      json =
        case headers_value do
          value when is_binary(value) -> value
          value when is_map(value) -> Jason.encode!(value)
        end

      encrypted = Liteskill.Crypto.encrypt(json)

      repo().query!(
        "UPDATE mcp_servers SET headers = $1 WHERE id = $2",
        [encrypted, id]
      )
    end)
  end

  def down do
    # Cannot reverse encryption — would need original values.
    # This is a one-way data migration.
    :ok
  end
end
