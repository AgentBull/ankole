defmodule Ankole.Repo.Migrations.DropScheduledEventFiringStatus do
  use Ecto.Migration

  def up do
    execute(
      "ALTER TABLE actor_scheduled_events DROP CONSTRAINT actor_scheduled_events_status_check"
    )

    execute(
      "ALTER TABLE actor_scheduled_events ADD CONSTRAINT actor_scheduled_events_status_check CHECK (status IN ('scheduled', 'fired', 'cancelled', 'failed'))"
    )
  end

  def down do
    execute(
      "ALTER TABLE actor_scheduled_events DROP CONSTRAINT actor_scheduled_events_status_check"
    )

    execute(
      "ALTER TABLE actor_scheduled_events ADD CONSTRAINT actor_scheduled_events_status_check CHECK (status IN ('scheduled', 'firing', 'fired', 'cancelled', 'failed'))"
    )
  end
end
