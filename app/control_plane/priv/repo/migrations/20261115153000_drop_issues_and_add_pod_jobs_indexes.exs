defmodule Ankole.Repo.Migrations.DropIssuesAndAddPodJobsIndexes do
  use Ecto.Migration

  # Pod `/jobs` projects Background Agent Jobs, Workflows, Cron Schedules,
  # pending checkbacks, and Page Automation Jobs directly from their domain
  # owners rather than maintaining a parallel `issues` table.
  def up do
    execute("DROP TABLE issues")

    execute("""
    CREATE INDEX background_agent_jobs_pod_live_idx
      ON background_agent_jobs (tenant_id, updated_at DESC)
      WHERE status IN ('queued', 'running', 'waiting_on_user')
    """)

    execute("""
    CREATE INDEX background_agent_jobs_pod_completed_idx
      ON background_agent_jobs (tenant_id, completed_at DESC)
      WHERE status IN ('succeeded', 'failed', 'stopped')
    """)

    execute("""
    CREATE INDEX workflow_runs_pod_live_idx
      ON workflow_runs (tenant_id, updated_at DESC)
      WHERE status = 'running'
    """)

    execute("""
    CREATE INDEX workflow_runs_pod_completed_idx
      ON workflow_runs (tenant_id, completed_at DESC)
      WHERE status IN ('completed', 'failed', 'cancelled')
    """)

    execute("""
    CREATE INDEX cron_schedules_pod_board_idx
      ON cron_schedules (tenant_id, next_fire_at ASC NULLS LAST)
      WHERE owner_job_id IS NULL AND status IN ('active', 'paused')
    """)

    execute("""
    CREATE INDEX scheduled_events_pod_checkbacks_idx
      ON scheduled_events (tenant_id, due_at ASC)
      WHERE kind = 'check_back_later' AND status IN ('scheduled', 'failed')
    """)
  end

  def down do
    execute("DROP INDEX scheduled_events_pod_checkbacks_idx")
    execute("DROP INDEX cron_schedules_pod_board_idx")
    execute("DROP INDEX workflow_runs_pod_completed_idx")
    execute("DROP INDEX workflow_runs_pod_live_idx")
    execute("DROP INDEX background_agent_jobs_pod_completed_idx")
    execute("DROP INDEX background_agent_jobs_pod_live_idx")

    execute("""
    CREATE TABLE issues (
      tenant_id       uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      conversation_id uuid NOT NULL,
      status          text NOT NULL CHECK (status IN ('todo','started','done')),
      description     text NOT NULL DEFAULT '',
      agent_uid       text,
      labels          text[] NOT NULL DEFAULT '{}',
      parent_id       uuid,
      squad_uids      text[] NOT NULL DEFAULT '{}',
      inserted_at     timestamptz NOT NULL,
      updated_at      timestamptz NOT NULL,
      PRIMARY KEY (tenant_id, conversation_id),
      CONSTRAINT issues_labels_check CHECK (cardinality(labels) <= 10),
      CONSTRAINT issues_squad_check CHECK (cardinality(squad_uids) <= 10),
      CONSTRAINT issues_parent_check CHECK (parent_id IS DISTINCT FROM conversation_id),
      CONSTRAINT issues_conversation_fkey FOREIGN KEY (tenant_id, conversation_id)
        REFERENCES conversations (tenant_id, id) ON DELETE CASCADE,
      CONSTRAINT issues_agent_fkey FOREIGN KEY (tenant_id, agent_uid)
        REFERENCES principals (tenant_id, uid) ON UPDATE CASCADE ON DELETE SET NULL (agent_uid),
      CONSTRAINT issues_parent_fkey FOREIGN KEY (tenant_id, parent_id)
        REFERENCES issues (tenant_id, conversation_id) ON DELETE SET NULL (parent_id)
    )
    """)

    execute("CREATE INDEX issues_agent_index ON issues (tenant_id, agent_uid)")
    execute("CREATE INDEX issues_parent_index ON issues (tenant_id, parent_id)")
  end
end
