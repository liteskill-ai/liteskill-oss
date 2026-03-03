defmodule Liteskill.Crypto.EncryptedMap do
  @moduledoc """
  Custom Ecto type that transparently encrypts a map on write and decrypts on read.

  Stored as an AES-256-GCM encrypted, base64-encoded text column.
  Use in schemas: `field :metadata, Liteskill.Crypto.EncryptedMap, default: %{}`
  """

  use Ecto.Type

  alias Liteskill.Crypto

  def type, do: :text

  def cast(nil), do: {:ok, %{}}
  def cast(value) when is_map(value), do: {:ok, value}
  def cast(_), do: :error

  def dump(nil), do: {:ok, nil}
  def dump(map) when map == %{}, do: {:ok, nil}

  def dump(map) when is_map(map) do
    case Jason.encode(map) do
      {:ok, json} -> {:ok, Crypto.encrypt(json)}
      _ -> :error
    end
  end

  def dump(_), do: :error

  def load(nil), do: {:ok, %{}}

  def load(value) when is_binary(value) do
    case Crypto.decrypt(value) do
      plaintext when is_binary(plaintext) ->
        case Jason.decode(plaintext) do
          {:ok, map} when is_map(map) -> {:ok, map}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  def load(_), do: :error

  def equal?(a, b), do: a == b
end
