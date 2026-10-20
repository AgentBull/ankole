defmodule Ankole.Repo.Migrations.RemoveUnusedPodSyncAndJobExpiry do
  use Ecto.Migration

  def up do
    execute("DROP TABLE db_sync_bindings")
    drop unique_index(:automation_jobs, [:tenant_id, :id])
    execute("ALTER TABLE db_records DROP COLUMN external_id")

    # An expired definition must stay terminal after expiry support is removed.
    execute("""
    UPDATE automation_jobs
    SET status = 'cancelled', cancelled_at = COALESCE(cancelled_at, updated_at)
    WHERE status = 'expired'
    """)

    execute("ALTER TABLE automation_jobs DROP CONSTRAINT automation_jobs_status_check")

    execute("ALTER TABLE automation_jobs DROP CONSTRAINT automation_jobs_terminal_time_check")

    execute("""
    ALTER TABLE automation_jobs
      DROP COLUMN expires_at,
      ADD CONSTRAINT automation_jobs_status_check CHECK (status IN ('active', 'cancelled')),
      ADD CONSTRAINT automation_jobs_terminal_time_check CHECK (
        (status = 'active' AND cancelled_at IS NULL) OR
        (status = 'cancelled' AND cancelled_at IS NOT NULL)
      )
    """)
  end

  def down do
    raise Ecto.MigrationError,
          "Removed sync bindings and job expiry values require the pre-upgrade database backup"
  end
end
