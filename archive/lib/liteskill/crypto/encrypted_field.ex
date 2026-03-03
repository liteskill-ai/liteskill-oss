defmodule Liteskill.Crypto.EncryptedField do
  @moduledoc """
  Custom Ecto type that transparently encrypts on write and decrypts on read.

  Use in schemas: `field :api_key, Liteskill.Crypto.EncryptedField`
  """

  use Ecto.Type

  alias Liteskill.Crypto

  def type, do: :string

  def cast(nil), do: {:ok, nil}
  def cast(value) when is_binary(value), do: {:ok, value}
  def cast(_), do: :error

  def dump(nil), do: {:ok, nil}
  def dump(value) when is_binary(value), do: {:ok, Crypto.encrypt(value)}
  def dump(_), do: :error

  def load(nil), do: {:ok, nil}

  def load(value) when is_binary(value) do
    case Crypto.decrypt(value) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      _ -> :error
    end
  end

  def load(_), do: :error
end
