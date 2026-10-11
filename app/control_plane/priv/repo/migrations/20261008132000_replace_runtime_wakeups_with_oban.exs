defmodule Ankole.Repo.Migrations.ReplaceRuntimeWakeupsWithOban do
  use Ecto.Migration

  def up do
    # Domain rows survive the old in-memory timers. Seed their deadlines once.
    seed("Ankole.Conversations.Jobs.EnsureDriver", "conversations", """
    SELECT jsonb_build_object('agent_uid', agent_uid, 'session_id', session_id) AS args,
           CASE WHEN session_id LIKE 'job:%'
                THEN (array_agg(available_at ORDER BY queue_sequence))[1]
                ELSE min(available_at) END AS due_at
    FROM actor_events
    WHERE input_state = 'open' AND completed_at IS NULL
    GROUP BY agent_uid, session_id
    """)

    seed("Ankole.SignalsGateway.Jobs.InboundBatchFinalize", "conversations", """
    SELECT jsonb_build_object('batch_id', id, 'batch_revision', batch_revision) AS args,
           available_at AS due_at
    FROM signal_gateway_inbound_batches WHERE batch_state = 'open'
    """)

    seed("Ankole.SignalsGateway.Jobs.OutboxDispatch", "outbox", """
    SELECT jsonb_build_object('agent_uid', agent_uid, 'binding_name', binding_name,
                             'outbound_key', outbound_key) AS args,
           CASE WHEN status = 'sending' THEN platform_send_started_at + interval '60 seconds'
                ELSE coalesce(next_attempt_at, timezone('UTC', now())) END AS due_at
    FROM signal_gateway_outbox_entries
    WHERE status = 'created'
       OR (status IN ('failed', 'unknown_after_send') AND next_attempt_at IS NOT NULL
           AND attempt_count < max_attempts)
       OR (status = 'sending' AND platform_send_started_at IS NOT NULL)
    """)

    seed("Ankole.SignalsGateway.Jobs.ReplyPreviewCheckpoint", "outbox", """
    SELECT jsonb_build_object('actor_event_id', id) AS args,
           timezone('UTC', now()) AS due_at
    FROM actor_events
    WHERE reply_preview_checkpoint IS NOT NULL
      AND coalesce(reply_preview_checkpoint->'recovery_state'->>'state', '') NOT IN ('blocked', 'permanent')
      AND (coalesce((reply_preview_checkpoint->>'presentation_owner')::boolean, true)
           OR coalesce((reply_preview_checkpoint->>'refresh_pending')::boolean, false))
      AND ((((input_state = 'open' AND completed_at IS NULL) OR completed_at IS NOT NULL)
            AND coalesce(reply_preview_checkpoint->>'streaming_state', 'open') NOT IN ('closed', 'replaced'))
           OR coalesce((reply_preview_checkpoint->>'refresh_pending')::boolean, false))
    """)

    seed("Ankole.SignalsGateway.Jobs.ReplyPreviewCleanup", "outbox", """
    SELECT jsonb_build_object('actor_event_id', id) AS args, reply_preview_cleanup_at AS due_at
    FROM actor_events WHERE reply_preview_cleanup_at IS NOT NULL
    """)

    seed("Ankole.AIGateway.Jobs.ReconcileOrphanedResponse", "conversations", """
    SELECT jsonb_build_object('message_id', id) AS args,
           coalesce(updated_at, inserted_at) + interval '300 seconds' AS due_at
    FROM ai_gateway_messages WHERE type = 'message' AND status = 'generating'
    """)

    seed("Ankole.Workflow.Jobs.PokeRun", "conversations", """
    SELECT jsonb_build_object('run_id', id) AS args, timezone('UTC', now()) AS due_at
    FROM workflow_runs WHERE cleanup_completed_at IS NULL
    """)

    drop table(:actor_event_deliveries)
    drop table(:actor_session_activations)
  end

  def down do
    raise "Conversation ownership cannot revert to activations. Restore the pre-upgrade backup."
  end

  defp seed(worker, queue, query) do
    execute """
    INSERT INTO oban_jobs (worker, queue, args, scheduled_at, state, max_attempts)
    SELECT '#{worker}', '#{queue}', pending.args, pending.due_at,
           CASE WHEN pending.due_at > timezone('UTC', now()) THEN 'scheduled' ELSE 'available' END::oban_job_state, 5
    FROM (#{query}) AS pending
    WHERE NOT EXISTS (
      SELECT 1 FROM oban_jobs job WHERE job.worker = '#{worker}' AND job.args = pending.args
      AND job.state IN ('available', 'scheduled', 'retryable', 'executing')
    )
    """
  end
end
