defmodule Liteskill.Repo.Migrations.AddCommentReplies do
  use Ecto.Migration

  def change do
    alter table(:section_comments) do
      add :parent_comment_id,
          references(:section_comments, type: :binary_id, on_delete: :delete_all)
    end

    create index(:section_comments, [:parent_comment_id])
  end
end
