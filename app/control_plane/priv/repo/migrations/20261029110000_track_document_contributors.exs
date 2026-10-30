defmodule Ankole.Repo.Migrations.TrackDocumentContributors do
  use Ecto.Migration

  def up do
    alter table(:page_contents) do
      add :contributors, {:array, :text}
    end

    flush()

    execute("""
    UPDATE page_contents AS content SET contributors = ARRAY(
      SELECT DISTINCT author FROM (
        SELECT page.created_by AS author
        UNION ALL SELECT content.updated_by
        UNION ALL
        SELECT change.author FROM page_changes AS change
        WHERE change.tenant_id = content.tenant_id AND change.page_id = content.page_id
      ) AS attribution
      ORDER BY author
    )
    FROM pages AS page
    WHERE page.tenant_id = content.tenant_id AND page.id = content.page_id
    """)

    alter table(:page_contents) do
      modify :contributors, {:array, :text}, null: false
    end
  end

  def down do
    alter table(:page_contents) do
      remove :contributors
    end
  end
end
