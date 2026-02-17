defmodule Liteskill.DataSources.Document do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "documents" do
    field :title, :string
    field :content, :string
    field :content_type, :string, default: "markdown"
    field :metadata, :map, default: %{}
    field :source_ref, :string
    field :slug, :string
    field :external_id, :string
    field :content_hash, :string

    belongs_to :user, Liteskill.Accounts.User
    belongs_to :parent_document, __MODULE__
    has_many :children, __MODULE__, foreign_key: :parent_document_id
    field :position, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def changeset(document, attrs) do
    document
    |> cast(attrs, [
      :title,
      :content,
      :content_type,
      :metadata,
      :source_ref,
      :slug,
      :external_id,
      :content_hash,
      :user_id,
      :parent_document_id,
      :position
    ])
    |> validate_required([:title, :source_ref, :user_id])
    |> validate_inclusion(:content_type, ["markdown", "text", "html"])
    |> maybe_generate_slug()
    |> unique_constraint([:source_ref, :parent_document_id, :slug],
      name: :documents_source_ref_parent_slug_index,
      message: "a page with this title already exists in this space"
    )
    |> unique_constraint([:source_ref, :slug],
      name: :documents_source_ref_root_slug_index,
      message: "a space with this title already exists"
    )
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:parent_document_id)
  end

  defp maybe_generate_slug(changeset) do
    case get_change(changeset, :slug) do
      nil ->
        case get_change(changeset, :title) do
          nil -> changeset
          title -> put_change(changeset, :slug, slugify(title))
        end

      _ ->
        changeset
    end
  end

  defp slugify(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/[\s]+/, "-")
    |> String.trim("-")
  end
end
