defmodule Ankole.Repo.Migrations.SeparateBrainProjectionWatermarks do
  use Ecto.Migration

  def up do
    alter table(:brain_objects) do
      add :timelines_extracted_at, :utc_datetime_usec
    end

    execute("""
    UPDATE brain_objects
    SET timelines_extracted_at = links_extracted_at, links_extracted_at = NULL
    """)
  end

  def down do
    alter table(:brain_objects) do
      remove :timelines_extracted_at
    end
  end
end
