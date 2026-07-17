defmodule Ankole.Repo.Migrations.DetachBackgroundAgentJobEventsFromSourceEntries do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE actor_events AS event
    SET source_entry_id = NULL,
        updated_at = CURRENT_TIMESTAMP
    FROM background_agent_jobs AS job
    WHERE event.agent_uid = job.agent_uid
      AND event.session_id = 'job:' || job.id::text
      AND event.type IN ('background_agent_job.dispatch', 'command.steer', 'command.stop')
      AND event.source_entry_id IS NOT NULL
    """)
  end

  def down do
    execute("""
    UPDATE actor_events AS event
    SET source_entry_id = NULLIF(job.reply_route->>'source_entry_id', ''),
        updated_at = CURRENT_TIMESTAMP
    FROM background_agent_jobs AS job
    WHERE event.agent_uid = job.agent_uid
      AND event.session_id = 'job:' || job.id::text
      AND event.type IN ('background_agent_job.dispatch', 'command.steer', 'command.stop')
      AND event.source_entry_id IS NULL
    """)
  end
end
