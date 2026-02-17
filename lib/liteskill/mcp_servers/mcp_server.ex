defmodule Liteskill.McpServers.McpServer do
  @moduledoc """
  Schema for MCP (Model Context Protocol) server registrations.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "mcp_servers" do
    field :name, :string
    field :url, :string
    field :api_key, Liteskill.Crypto.EncryptedField
    field :description, :string
    field :headers, Liteskill.Crypto.EncryptedMap, default: %{}
    field :status, :string, default: "active"
    field :global, :boolean, default: false

    belongs_to :user, Liteskill.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(server, attrs, opts \\ []) do
    server
    |> cast(attrs, [:name, :url, :api_key, :description, :headers, :status, :global, :user_id])
    |> validate_required([:name, :url, :user_id])
    |> validate_inclusion(:status, ["active", "inactive"])
    |> validate_url(:url, opts)
    |> foreign_key_constraint(:user_id)
  end

  defp validate_url(changeset, field, opts) do
    validate_change(changeset, field, fn _, value ->
      case URI.parse(value) do
        %URI{scheme: scheme, host: host}
        when scheme in ["https", "http"] and is_binary(host) and host != "" ->
          cond do
            scheme == "http" and !opts[:allow_private_urls] ->
              [{field, "must be a valid HTTPS URL"}]

            !opts[:allow_private_urls] and private_host?(host) ->
              [{field, "must not point to a private or reserved address"}]

            true ->
              []
          end

        _ ->
          [{field, "must be a valid HTTPS URL"}]
      end
    end)
  end

  defp private_host?(host) do
    lower = String.downcase(host)

    lower == "localhost" or
      String.starts_with?(lower, "127.") or
      String.starts_with?(lower, "10.") or
      String.starts_with?(lower, "192.168.") or
      String.starts_with?(lower, "169.254.") or
      String.starts_with?(lower, "0.") or
      Regex.match?(~r/^172\.(1[6-9]|2[0-9]|3[01])\./, lower) or
      lower in ["[::1]", "::1"] or
      String.starts_with?(lower, "[fc") or
      String.starts_with?(lower, "[fd") or
      String.starts_with?(lower, "[fe80") or
      String.starts_with?(lower, "fc") or
      String.starts_with?(lower, "fd") or
      String.starts_with?(lower, "fe80")
  end
end
