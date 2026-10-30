defmodule Ankole.Repo.Migrations.TrackCommentActivity do
  use Ecto.Migration

  def up do
    alter table(:page_user_states), do: add(:comments_read_at, :utc_datetime_usec)

    alter table(:page_comments) do
      add(:activity_at, :utc_datetime_usec)
      add(:activity_by, :text)
    end

    execute("UPDATE page_comments SET activity_at = updated_at, activity_by = updated_by")

    execute("""
    UPDATE page_comments root SET activity_at = latest.activity_at, activity_by = latest.activity_by
    FROM (
      SELECT DISTINCT ON (tenant_id, page_id, COALESCE(root_id, id))
        tenant_id, page_id, COALESCE(root_id, id) AS root_id, activity_at, activity_by
      FROM page_comments ORDER BY tenant_id, page_id, COALESCE(root_id, id), activity_at DESC, id DESC
    ) latest
    WHERE root.tenant_id = latest.tenant_id AND root.page_id = latest.page_id AND root.id = latest.root_id
    """)

    execute(
      "ALTER TABLE page_comments ALTER COLUMN activity_at SET NOT NULL, ALTER COLUMN activity_by SET NOT NULL"
    )

    execute(
      "CREATE INDEX page_comments_activity ON page_comments(tenant_id, page_id, activity_at DESC, id DESC) WHERE root_id IS NULL"
    )
  end

  def down do
    raise Ecto.MigrationError,
      message: "Comment read state requires restoring the database backup."
  end
end
