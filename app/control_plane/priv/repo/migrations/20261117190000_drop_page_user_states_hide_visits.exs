defmodule Ankole.Repo.Migrations.DropPageUserStatesHideVisits do
  use Ecto.Migration

  def up do
    execute("""
    DELETE FROM page_user_states
    WHERE favorited_at IS NULL
      AND visited_at IS NULL
      AND comments_read_at IS NULL
      AND edited_at IS NULL
    """)

    drop(
      index(:page_user_states, [:tenant_id, :page_id, :visited_at, :principal_uid],
        name: :page_user_states_viewers
      )
    )

    alter table(:page_user_states) do
      remove(:hide_visits)
    end

    create(
      index(:page_user_states, [:tenant_id, :page_id, :visited_at, :principal_uid],
        name: :page_user_states_viewers,
        where: "visited_at IS NOT NULL"
      )
    )
  end

  def down do
    drop(
      index(:page_user_states, [:tenant_id, :page_id, :visited_at, :principal_uid],
        name: :page_user_states_viewers
      )
    )

    alter table(:page_user_states) do
      add(:hide_visits, :boolean, null: false, default: false)
    end

    create(
      index(:page_user_states, [:tenant_id, :page_id, :visited_at, :principal_uid],
        name: :page_user_states_viewers,
        where: "visited_at IS NOT NULL AND NOT hide_visits"
      )
    )
  end
end
