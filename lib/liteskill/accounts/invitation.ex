defmodule Liteskill.Accounts.Invitation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @token_bytes 32
  @expires_in_days 7

  schema "invitations" do
    field :email, :string
    field :token, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime

    belongs_to :created_by, Liteskill.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [:email, :created_by_id])
    |> validate_required([:email])
    |> validate_format(:email, ~r/@/)
    |> update_change(:email, &String.downcase/1)
    |> put_token()
    |> put_expires_at()
  end

  def expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end

  def used?(%__MODULE__{used_at: nil}), do: false
  def used?(%__MODULE__{}), do: true

  defp put_token(changeset) do
    if get_change(changeset, :token) do
      changeset
    else
      put_change(changeset, :token, generate_token())
    end
  end

  defp put_expires_at(changeset) do
    if get_change(changeset, :expires_at) do
      changeset
    else
      expires =
        DateTime.utc_now()
        |> DateTime.add(@expires_in_days * 24 * 3600)
        |> DateTime.truncate(:second)

      put_change(changeset, :expires_at, expires)
    end
  end

  defp generate_token do
    :crypto.strong_rand_bytes(@token_bytes) |> Base.url_encode64(padding: false)
  end
end
