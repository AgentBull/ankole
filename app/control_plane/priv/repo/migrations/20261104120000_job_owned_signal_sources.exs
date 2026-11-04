defmodule Ankole.Repo.Migrations.JobOwnedSignalSources do
  use Ecto.Migration

  def up do
    sql = """
    ALTER TABLE cron_schedules
      ADD COLUMN owner_job_id bigint,
      ALTER COLUMN agent_uid DROP NOT NULL,
      ALTER COLUMN owner_session_id DROP NOT NULL,
      ALTER COLUMN delivery DROP NOT NULL,
      ADD CONSTRAINT cron_schedules_owner_job_fkey
        FOREIGN KEY (tenant_id, owner_job_id) REFERENCES automation_jobs(tenant_id, id) ON DELETE CASCADE,
      ADD CONSTRAINT cron_schedules_owner_scope_check CHECK (
        (owner_job_id IS NOT NULL AND agent_uid IS NULL AND owner_session_id IS NULL AND delivery IS NULL AND binding_name IS NULL)
        OR (owner_job_id IS NULL AND agent_uid IS NOT NULL AND owner_session_id IS NOT NULL AND delivery IS NOT NULL)
      );
    DROP INDEX cron_schedules_agent_name_index;
    DROP INDEX cron_schedules_idempotency_index;
    CREATE UNIQUE INDEX cron_schedules_agent_name_index ON cron_schedules (tenant_id, agent_uid, owner_session_id, name) WHERE owner_job_id IS NULL AND status <> 'deleted';
    CREATE UNIQUE INDEX cron_schedules_idempotency_index ON cron_schedules (tenant_id, agent_uid, owner_session_id, idempotency_key) WHERE owner_job_id IS NULL;
    CREATE UNIQUE INDEX cron_schedules_job_name_index ON cron_schedules (tenant_id, owner_job_id, name) WHERE owner_job_id IS NOT NULL AND status <> 'deleted';
    CREATE UNIQUE INDEX cron_schedules_job_idempotency_index ON cron_schedules (tenant_id, owner_job_id, idempotency_key) WHERE owner_job_id IS NOT NULL;

    ALTER TABLE scheduled_events
      ALTER COLUMN agent_uid DROP NOT NULL,
      ALTER COLUMN session_id DROP NOT NULL,
      ADD CONSTRAINT scheduled_events_scope_check CHECK (
        (kind = 'check_back_later' AND agent_uid IS NOT NULL AND session_id IS NOT NULL)
        OR (kind = 'cron_fire' AND cron_schedule_id IS NOT NULL AND
            ((agent_uid IS NULL AND session_id IS NULL) OR (agent_uid IS NOT NULL AND session_id IS NOT NULL)))
      );
    DROP INDEX scheduled_events_idempotency_index;
    CREATE UNIQUE INDEX scheduled_events_idempotency_index ON scheduled_events (tenant_id, kind, agent_uid, session_id, idempotency_key) WHERE agent_uid IS NOT NULL;
    CREATE UNIQUE INDEX scheduled_events_cron_manual_idempotency_index ON scheduled_events (tenant_id, cron_schedule_id, idempotency_key) WHERE kind = 'cron_fire';

    ALTER TABLE signal_webhook_endpoints
      DROP CONSTRAINT signal_webhook_endpoints_raw_target_check,
      DROP CONSTRAINT signal_webhook_endpoints_status_check,
      DROP CONSTRAINT signal_webhook_endpoints_lifecycle_check,
      ADD COLUMN owner_job_id bigint,
      ADD COLUMN authorization_kind text NOT NULL DEFAULT 'service',
      ADD COLUMN human_uid text,
      ADD COLUMN human_access_version integer,
      ADD CONSTRAINT signal_webhook_endpoints_owner_job_fkey
        FOREIGN KEY (tenant_id, owner_job_id) REFERENCES automation_jobs(tenant_id, id) ON DELETE CASCADE,
      ADD CONSTRAINT signal_webhook_endpoints_work_authorization_check CHECK (
        (authorization_kind = 'human' AND human_uid IS NOT NULL AND human_access_version IS NOT NULL)
        OR (authorization_kind = 'service' AND human_uid IS NULL AND human_access_version IS NULL)
        OR authorization_kind = 'review_required'
      ),
      ADD CONSTRAINT signal_webhook_endpoints_status_check CHECK (status IN ('armed','active','paused','fired','cancelled','expired')),
      ADD CONSTRAINT signal_webhook_endpoints_lifecycle_check CHECK (
        (status = 'fired' AND fired_at IS NOT NULL AND cancelled_at IS NULL)
        OR (status = 'cancelled' AND cancelled_at IS NOT NULL AND fired_at IS NULL)
        OR (status IN ('armed','active','paused','expired') AND fired_at IS NULL AND cancelled_at IS NULL)
      ),
      ADD CONSTRAINT signal_webhook_endpoints_owner_scope_check CHECK (
        (owner_job_id IS NOT NULL AND agent_uid IS NULL AND session_id IS NULL)
        OR (owner_job_id IS NULL AND (event_format = 'cloudevents' OR (agent_uid IS NOT NULL AND session_id IS NOT NULL)))
      );
    UPDATE signal_webhook_endpoints w SET
      authorization_kind = s.authorization_kind,
      human_uid = s.human_uid,
      human_access_version = s.human_access_version
    FROM signals s WHERE s.tenant_id = w.tenant_id AND s.id = w.source_signal_id;
    """

    sql |> String.split(";", trim: true) |> Enum.each(&execute/1)
  end

  def down do
    raise "Job-owned signal sources must be removed before restoring the Agent-only schema"
  end
end
