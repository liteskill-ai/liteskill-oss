defmodule Liteskill.Crypto.EncryptedMapTest do
  use ExUnit.Case, async: true

  alias Liteskill.Crypto.EncryptedMap

  describe "type/0" do
    test "returns :text" do
      assert EncryptedMap.type() == :text
    end
  end

  describe "cast/1" do
    test "casts nil to empty map" do
      assert {:ok, %{}} = EncryptedMap.cast(nil)
    end

    test "casts a map as-is" do
      map = %{"key" => "value"}
      assert {:ok, ^map} = EncryptedMap.cast(map)
    end

    test "rejects non-map values" do
      assert :error = EncryptedMap.cast("string")
      assert :error = EncryptedMap.cast(42)
      assert :error = EncryptedMap.cast([1, 2])
    end
  end

  describe "dump/1" do
    test "dumps nil to nil" do
      assert {:ok, nil} = EncryptedMap.dump(nil)
    end

    test "dumps empty map to nil" do
      assert {:ok, nil} = EncryptedMap.dump(%{})
    end

    test "dumps non-empty map to encrypted string" do
      map = %{"api_key" => "secret123"}
      assert {:ok, encrypted} = EncryptedMap.dump(map)
      assert is_binary(encrypted)
      # Should be base64 encoded
      assert {:ok, _} = Base.decode64(encrypted)
      # Should NOT be readable plaintext
      refute encrypted =~ "secret123"
    end

    test "rejects non-map values" do
      assert :error = EncryptedMap.dump("string")
    end
  end

  describe "load/1" do
    test "loads nil to empty map" do
      assert {:ok, %{}} = EncryptedMap.load(nil)
    end

    test "round-trips through dump and load" do
      original = %{"token" => "ghp_abc123", "repo" => "owner/repo"}
      {:ok, encrypted} = EncryptedMap.dump(original)
      assert {:ok, ^original} = EncryptedMap.load(encrypted)
    end

    test "returns error for invalid encrypted data" do
      assert :error = EncryptedMap.load("not-valid-encrypted-data")
    end

    test "returns error for non-binary values" do
      assert :error = EncryptedMap.load(42)
    end
  end

  describe "equal?/2" do
    test "equal maps are equal" do
      a = %{"k" => "v"}
      b = %{"k" => "v"}
      assert EncryptedMap.equal?(a, b)
    end

    test "different maps are not equal" do
      a = %{"k" => "v1"}
      b = %{"k" => "v2"}
      refute EncryptedMap.equal?(a, b)
    end

    test "empty maps are equal" do
      assert EncryptedMap.equal?(%{}, %{})
    end
  end
end
