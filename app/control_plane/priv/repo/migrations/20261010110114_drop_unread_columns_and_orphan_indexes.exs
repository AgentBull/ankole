defmodule Ankole.Repo.Migrations.DropUnreadColumnsAndOrphanIndexes do
  use Ecto.Migration

  def up do
    execute("DROP INDEX actor_events_recoverable_reply_preview_index")
    execute("DROP INDEX actor_events_reply_preview_cleanup_at_index")
    execute("DROP INDEX signal_gateway_inbound_batches_due_index")
    execute("DROP INDEX actor_scheduled_events_oban_job_index")

    drop constraint(:signal_gateway_inbound_batches, :inbound_batches_outcome_check)

    alter table(:actor_events) do
      remove :reply_preview_cleanup_at
    end

    alter table(:actor_scheduled_events) do
      remove :oban_job_id
    end

    alter table(:automation_job_runs) do
      remove :oban_job_id
      remove :last_attempt_at
    end

    alter table(:signal_gateway_outbox_entries) do
      remove :last_attempted_at
    end

    alter table(:signal_gateway_inbound_batches) do
      remove :hard_cap_at
      remove :outcome
      remove :finalized_at
      remove :actor_event_id
    end

    alter table(:background_agent_jobs) do
      remove :workspace_mounts
    end
  end

  def down do
    raise Ecto.MigrationError,
      message: "Unread columns and orphan indexes were removed; restore the pre-upgrade backup"
  end
end
