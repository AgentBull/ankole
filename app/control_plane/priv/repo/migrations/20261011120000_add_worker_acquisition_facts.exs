defmodule Ankole.Repo.Migrations.AddWorkerAcquisitionFacts do
  use Ecto.Migration

  def up do
    alter table(:agent_workers) do
      add :last_error_kind, :text
      add :create_sent_at, :utc_datetime_usec
    end

    # Old failures have no classification. Keep them retryable. A generation
    # that predates this migration may already have sent its create request.
    # The epoch keeps the old orphan gate until that generation ends; a later
    # lifecycle state time cannot bound its first send.
    execute "UPDATE agent_workers SET last_error_kind = 'transient' WHERE last_error IS NOT NULL"

    execute "UPDATE agent_workers SET create_sent_at = TIMESTAMP '1970-01-01 00:00:00' WHERE generation IS NOT NULL"

    create constraint(:agent_workers, :agent_workers_error_kind,
             check: "last_error_kind IN ('rejected', 'transient', 'pending')"
           )

    create constraint(:agent_workers, :agent_workers_error_pair,
             check: "(last_error IS NULL) = (last_error_kind IS NULL)"
           )

    create constraint(:agent_workers, :agent_workers_create_sent_generation,
             check: "generation IS NOT NULL OR create_sent_at IS NULL"
           )
  end

  def down do
    drop constraint(:agent_workers, :agent_workers_create_sent_generation)
    drop constraint(:agent_workers, :agent_workers_error_pair)
    drop constraint(:agent_workers, :agent_workers_error_kind)

    alter table(:agent_workers) do
      remove :create_sent_at
      remove :last_error_kind
    end
  end
end
