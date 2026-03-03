defmodule Liteskill.Repo.Migrations.EncryptMcpApiKeys do
  use Ecto.Migration

  def up do
    # Migrate existing plaintext API keys to encrypted format.
    # After this migration, all api_key values are AES-256-GCM encrypted
    # and base64 encoded.
    flush()

    repo().query!(
      "SELECT id, api_key FROM mcp_servers WHERE api_key IS NOT NULL",
      []
    )
    |> Map.get(:rows, [])
    |> Enum.each(fn [id, plaintext_key] ->
      encrypted = Liteskill.Crypto.encrypt(plaintext_key)

      repo().query!(
        "UPDATE mcp_servers SET api_key = $1 WHERE id = $2",
        [encrypted, id]
      )
    end)
  end

  def down do
    # Cannot reverse encryption — would need original keys.
    # This is a one-way data migration.
    :ok
  end
end
