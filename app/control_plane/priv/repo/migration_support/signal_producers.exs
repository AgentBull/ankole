defmodule Ankole.Repo.Migrations.SignalProducers do
  @moduledoc false

  def add_if_missing(repo) do
    %{rows: [[exists?]]} =
      repo.query!(
        """
        SELECT EXISTS(SELECT 1 FROM information_schema.columns
          WHERE table_schema='public' AND table_name='signals' AND column_name='producer')
        """,
        []
      )

    unless exists? do
      repo.query!(
        """
        ALTER TABLE signals ADD COLUMN producer text NOT NULL DEFAULT 'external';
        ALTER TABLE signals ADD CONSTRAINT signals_producer_check
          CHECK (producer IN ('kernel','external'));
        """,
        [],
        query_type: :text,
        timeout: :infinity
      )
    end

    not exists?
  end

  # This runs only when provenance is introduced to legacy rows. A supplied
  # source URI or JSON claim alone never proves kernel ownership. Existing
  # explicit provenance is never reclassified by a later migration.
  def backfill(repo) do
    repo.query!(
      """
      UPDATE signals s SET producer='kernel'
      WHERE s.producer='external' AND s.type<>'webhook.received' AND (
        EXISTS (SELECT 1 FROM conversation_messages m
          JOIN conversations c ON c.tenant_id=m.tenant_id AND c.id=m.conversation_id
          WHERE m.tenant_id=s.tenant_id AND m.id=s.message_id AND c.kind='native')
        OR EXISTS (SELECT 1 FROM scheduled_events e
          WHERE e.tenant_id=s.tenant_id AND e.signal_id=s.id AND e.agent_uid=s.agent_uid
            AND e.session_id=s.session_id AND e.status='fired' AND e.fired_at IS NOT NULL
            AND ((e.kind='cron_fire' AND s.type='cron.fire')
              OR (e.kind='check_back_later' AND s.type='check_back_later.wakeup')))
        OR EXISTS (SELECT 1 FROM signal_gateway_bindings b
          JOIN signal_gateway_entries e ON e.tenant_id=b.tenant_id
          WHERE b.tenant_id=s.tenant_id AND b.agent_uid=s.agent_uid AND b.name=s.reply_binding_name
            AND b.adapter IN ('discord','dingtalk','email','lark','line','slack','teams','telegram','wecom','whatsapp')
            AND e.signal_channel_id=s.signal_channel_id AND e.source_entry_id=s.source_entry_id
            AND (s.type IN ('im.message.addressed','conversation.message.addressed','im.message.may_intervene',
              'signal.entry.removed','signal.action.invoked','input.revised') OR starts_with(s.type,'command.')))
        OR EXISTS (SELECT 1 FROM background_agent_jobs j
          WHERE j.tenant_id=s.tenant_id AND j.agent_uid=s.agent_uid
            AND j.id::text=s.data->>'job_id'
            AND ((s.type='background_agent_job.dispatch' AND s.session_id='job:'||j.id::text)
              OR (s.session_id=j.owner_session_id AND
                ((s.type='background_agent_job.completed' AND j.status='succeeded')
                  OR (s.type='background_agent_job.failed' AND j.status='failed')
                  OR s.type='background_agent_job.waiting'))))
        OR EXISTS (SELECT 1 FROM workflow_agent_calls c
          JOIN workflow_runs r ON r.tenant_id=c.tenant_id AND r.id=c.run_id
          WHERE c.tenant_id=s.tenant_id AND c.agent_uid=s.agent_uid AND r.agent_uid=s.agent_uid
            AND c.id::text=s.data->>'call_id' AND s.session_id='wf_task:'||c.id::text
            AND s.type IN ('workflow.task.dispatch','workflow.task.wakeup','workflow.task.message'))
        OR EXISTS (SELECT 1 FROM workflow_agent_calls c
          JOIN workflow_runs r ON r.tenant_id=c.tenant_id AND r.id=c.run_id
          WHERE c.tenant_id=s.tenant_id AND c.agent_uid=s.agent_uid AND r.agent_uid=s.agent_uid
            AND s.session_id='wf_task:'||c.id::text AND s.type='command.stop'
            AND s.source_event_id='workflow:call:'||c.id::text||':stop')
        OR EXISTS (SELECT 1 FROM workflow_runs r
          WHERE r.tenant_id=s.tenant_id AND r.agent_uid=s.agent_uid AND r.owner_session_id=s.session_id
            AND r.id::text=s.data->>'run_id'
            AND ((s.type='workflow.run.completed' AND r.status='completed')
              OR (s.type='workflow.run.failed' AND r.status='failed')
              OR s.type='workflow.run.attention'))
        OR EXISTS (SELECT 1 FROM automation_job_runs r
          JOIN automation_jobs j ON j.tenant_id=r.tenant_id AND j.id=r.automation_job_id
          WHERE j.tenant_id=s.tenant_id AND j.agent_uid=s.agent_uid AND j.owner_session_id=s.session_id
            AND r.id::text=s.data->>'automation_job_run_id'
            AND (s.type='automation_job.emitted' OR (s.type='automation_job.run_failed' AND r.status='failed')))
        OR EXISTS (SELECT 1 FROM ai_gateway_conversations c
          WHERE c.tenant_id=s.tenant_id AND c.subject_uid=s.agent_uid AND c.conversation_key=s.session_id
            AND s.type='session.reset_due')
      );
      UPDATE signals s SET producer='kernel'
      FROM signals parent
      WHERE s.producer='external' AND s.type='input.revised'
        AND parent.tenant_id=s.tenant_id AND parent.agent_uid=s.agent_uid
        AND parent.session_id=s.session_id AND parent.producer='kernel'
        AND parent.id::text=s.data#>>'{revision,signal_id}';
      UPDATE signals s SET producer='kernel'
      FROM signals parent, signals command
      WHERE s.producer='external' AND s.type=parent.type
        AND parent.tenant_id=s.tenant_id AND parent.agent_uid=s.agent_uid
        AND parent.session_id=s.session_id AND parent.producer='kernel'
        AND parent.id::text=s.data#>>'{entry,retry_of_signal_id}'
        AND command.tenant_id=s.tenant_id AND command.agent_uid=s.agent_uid
        AND command.session_id=s.session_id AND command.producer='kernel'
        AND command.type='command.retry' AND s.source_event_id='retry:'||command.id::text;
      """,
      [],
      query_type: :text,
      timeout: :infinity
    )
  end
end
