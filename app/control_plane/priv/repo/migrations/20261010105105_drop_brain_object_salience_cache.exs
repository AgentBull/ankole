defmodule Ankole.Repo.Migrations.DropBrainObjectSalienceCache do
  use Ecto.Migration

  def up do
    drop constraint(:brain_objects, :brain_objects_emotional_weight_range)

    alter table(:brain_objects) do
      remove :emotional_weight
      remove :emotional_weight_recomputed_at
      remove :salience_touched_at
    end
  end

  def down do
    raise Ecto.MigrationError,
      message: "Brain salience is computed from active Takes; restore the pre-upgrade backup"
  end
end
