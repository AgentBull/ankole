defmodule Ankole.Repo.Migrations.TrackDocumentActivity do
  use Ecto.Migration

  def change do
    alter table(:page_user_states) do
      add(:hide_visits, :boolean, null: false, default: false)
      add(:edited_at, :utc_datetime_usec)
    end

    execute(
      """
      CREATE TABLE page_daily_activity (
        tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
        page_id uuid NOT NULL,
        day date NOT NULL,
        views bigint NOT NULL DEFAULT 0,
        edits bigint NOT NULL DEFAULT 0,
        comments bigint NOT NULL DEFAULT 0,
        PRIMARY KEY (tenant_id, page_id, day),
        CONSTRAINT page_daily_activity_counts CHECK (views >= 0 AND edits >= 0 AND comments >= 0),
        CONSTRAINT page_daily_activity_page_fkey FOREIGN KEY (tenant_id, page_id)
          REFERENCES pages(tenant_id, id) ON DELETE CASCADE
      )
      """,
      "DROP TABLE page_daily_activity"
    )

    create(
      index(:page_user_states, [:tenant_id, :page_id, :visited_at, :principal_uid],
        name: :page_user_states_viewers,
        where: "visited_at IS NOT NULL AND NOT hide_visits"
      )
    )
  end
end
