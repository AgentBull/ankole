defmodule Ankole.Repo.Migrations.RecordActorEventDeadLetterReason do
  use Ecto.Migration

  def change do
    alter table(:actor_events) do
      add :dead_letter_reason, :jsonb
    end
  end
end
