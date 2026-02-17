defmodule Liteskill.Crypto do
  @moduledoc """
  AES-256-GCM encryption for sensitive data at rest.

  Uses a 32-byte key derived from the `:encryption_key` application config.
  The ciphertext format is: IV (12 bytes) || tag (16 bytes) || ciphertext,
  stored as base64 for string-column compatibility.
  """
  use Boundary, top_level?: true, deps: [], exports: [EncryptedField, EncryptedMap]

  @iv_length 12
  @tag_length 16
  @aad "liteskill_encrypted_field"

  def encrypt(nil), do: nil
  def encrypt(""), do: nil

  def encrypt(plaintext) when is_binary(plaintext) do
    key = encryption_key()
    iv = :crypto.strong_rand_bytes(@iv_length)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, @aad, @tag_length, true)

    Base.encode64(iv <> tag <> ciphertext)
  end

  def decrypt(nil), do: nil

  def decrypt(encoded) when is_binary(encoded) do
    key = encryption_key()

    with {:ok, <<iv::binary-size(@iv_length), tag::binary-size(@tag_length), ciphertext::binary>>} <-
           Base.decode64(encoded) do
      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             iv,
             ciphertext,
             @aad,
             tag,
             false
           ) do
        plaintext when is_binary(plaintext) -> plaintext
        :error -> :error
      end
    end
  end

  @doc """
  Validates that the encryption key is configured. Call at application boot
  to fail fast instead of crashing on first encrypt/decrypt.
  """
  def validate_key! do
    encryption_key()
    :ok
  end

  defp encryption_key do
    # coveralls-ignore-start
    key_source =
      Application.get_env(:liteskill, :encryption_key) ||
        raise """
        Missing :encryption_key config for Liteskill.Crypto.
        Set ENCRYPTION_KEY env var (32+ chars) or configure in config.
        """

    # coveralls-ignore-stop

    # Derive a fixed 32-byte key via SHA-256
    :crypto.hash(:sha256, key_source)
  end
end
