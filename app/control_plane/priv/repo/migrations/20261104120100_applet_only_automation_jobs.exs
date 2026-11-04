defmodule Ankole.Repo.Migrations.AppletOnlyAutomationJobs do
  use Ecto.Migration

  def up do
    statements = """
    DELETE FROM signal_binding_receipts r USING signal_bindings b, automation_jobs j
      WHERE r.tenant_id = b.tenant_id AND r.binding_id = b.id
      AND b.tenant_id = j.tenant_id AND j.executor_kind = 'agent_script'
      AND (b.automation_job_id = j.id OR b.config_ref = 'job://' || j.id::text);
    DELETE FROM signal_bindings b USING automation_jobs j
      WHERE b.tenant_id = j.tenant_id AND j.executor_kind = 'agent_script'
      AND (b.automation_job_id = j.id OR b.config_ref = 'job://' || j.id::text);
    DELETE FROM automation_jobs WHERE executor_kind = 'agent_script';
    ALTER TABLE automation_jobs
      DROP CONSTRAINT automation_jobs_executor_mode_check,
      DROP COLUMN drive_prefix,
      DROP COLUMN wake_on_failure,
      DROP COLUMN agent_uid,
      DROP COLUMN owner_session_id,
      DROP COLUMN reply_route,
      DROP COLUMN provider_message_id,
      DROP COLUMN executor_kind,
      ALTER COLUMN page_id SET NOT NULL,
      ALTER COLUMN action_key SET NOT NULL;
    ALTER TABLE automation_job_runs DROP COLUMN worker_wait_started_at;
    """

    statements |> String.split(";", trim: true) |> Enum.each(&execute/1)
  end

  def down do
    raise "Applet-only automation Jobs cannot restore retired script executors"
  end
end
