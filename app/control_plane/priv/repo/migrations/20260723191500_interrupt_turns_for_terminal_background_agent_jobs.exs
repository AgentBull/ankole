defmodule Ankole.Repo.Migrations.InterruptTurnsForTerminalBackgroundAgentJobs do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE background_agent_job_turns AS turn
    SET
      status = 'interrupted',
      error = jsonb_build_object(
        'code',
        CASE
          WHEN job.status = 'failed'
            AND NULLIF(job.error->>'code', '') IS NOT NULL
            AND NULLIF(job.error->>'summary', '') IS NOT NULL
          THEN job.error->>'code'
          ELSE 'background_agent_job_' || job.status
        END,
        'summary',
        CASE
          WHEN job.status = 'failed'
            AND NULLIF(job.error->>'code', '') IS NOT NULL
            AND NULLIF(job.error->>'summary', '') IS NOT NULL
          THEN job.error->>'summary'
          ELSE 'The Job ' || job.status || ' before this runtime Turn reported completion.'
        END
      ),
      completed_at = timezone('UTC', now()),
      progress = turn.progress - 'active_item',
      revision = turn.revision + 1,
      updated_at = timezone('UTC', now())
    FROM background_agent_jobs AS job
    WHERE turn.job_id = job.id
      AND turn.status = 'in_progress'
      AND job.status IN ('succeeded', 'failed', 'stopped')
    """)
  end

  def down do
    :ok
  end
end
