defmodule Liteskill.CryptoTest do
  # async: false because the "encryption enabled" tests modify global Application config
  use ExUnit.Case, async: false

  alias Liteskill.Crypto

  describe "when encryption is not enabled (default)" do
    test "encrypt/1 returns nil for nil" do
      assert Crypto.encrypt(nil) == nil
    end

    test "encrypt/1 returns nil for empty string" do
      assert Crypto.encrypt("") == nil
    end

    test "encrypt/1 returns plaintext as-is" do
      assert Crypto.encrypt("my-secret-key") == "my-secret-key"
    end

    test "decrypt/1 returns nil for nil" do
      assert Crypto.decrypt(nil) == nil
    end

    test "decrypt/1 returns value as-is" do
      assert Crypto.decrypt("some-stored-value") == "some-stored-value"
    end

    test "validate_key!/0 is a no-op" do
      assert Crypto.validate_key!() == :ok
    end
  end

  describe "when encryption is enabled" do
    setup do
      prev = Application.get_env(:liteskill, :encryption_key)
      Application.put_env(:liteskill, :encryption_key, "test-crypto-key-for-unit-tests")

      on_exit(fn ->
        if prev,
          do: Application.put_env(:liteskill, :encryption_key, prev),
          else: Application.delete_env(:liteskill, :encryption_key)
      end)

      :ok
    end

    test "encrypt/1 returns nil for nil" do
      assert Crypto.encrypt(nil) == nil
    end

    test "encrypt/1 returns nil for empty string" do
      assert Crypto.encrypt("") == nil
    end

    test "encrypt/1 encrypts a plaintext string to base64" do
      ciphertext = Crypto.encrypt("my-secret-key")
      assert is_binary(ciphertext)
      assert {:ok, _} = Base.decode64(ciphertext)
      refute ciphertext == "my-secret-key"
    end

    test "encrypt/1 produces different ciphertexts for same input (random IV)" do
      a = Crypto.encrypt("same-value")
      b = Crypto.encrypt("same-value")
      assert a != b
    end

    test "decrypt/1 returns nil for nil" do
      assert Crypto.decrypt(nil) == nil
    end

    test "decrypt/1 round-trips through encrypt/decrypt" do
      original = "super-secret-api-key-12345"
      encrypted = Crypto.encrypt(original)
      assert Crypto.decrypt(encrypted) == original
    end

    test "decrypt/1 returns :error for invalid base64" do
      assert Crypto.decrypt("not-valid-base64!!!") == :error
    end

    test "decrypt/1 returns :error for tampered ciphertext" do
      encrypted = Crypto.encrypt("test-value")
      {:ok, raw} = Base.decode64(encrypted)
      # Flip a byte in the ciphertext portion
      tampered = Base.encode64(raw <> <<0>>)
      assert Crypto.decrypt(tampered) == :error
    end

    test "validate_key!/0 succeeds with key configured" do
      assert Crypto.validate_key!() == :ok
    end
  end
end
