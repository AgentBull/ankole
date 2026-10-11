defmodule Ankole.Repo.Migrations.ResolveLongLivedResourceOwners do
  use Ecto.Migration

  def up do
    execute """
    CREATE TEMP TABLE b07_long_lived_owners ON COMMIT DROP AS
    WITH RECURSIVE
    edges AS (
      SELECT job.tenant_id, job.agent_uid, 'job:' || job.id::text AS session_id,
             job.owner_session_id, job.reply_route
      FROM background_agent_jobs AS job
      JOIN ai_gateway_conversations AS conversation
        ON conversation.tenant_id = job.tenant_id
       AND conversation.subject_uid = job.agent_uid
       AND conversation.id::text = job.metadata->>'owner_conversation_id'
       AND conversation.conversation_key = job.owner_session_id
      WHERE jsonb_typeof(job.reply_route) = 'object'
      UNION ALL
      SELECT call.tenant_id, call.agent_uid, 'wf_task:' || call.id::text,
             run.owner_session_id, run.reply_route
      FROM workflow_agent_calls AS call
      JOIN workflow_runs AS run
        ON run.id = call.run_id AND run.tenant_id = call.tenant_id
       AND run.agent_uid = call.agent_uid
      WHERE jsonb_typeof(run.reply_route) = 'object'
    ),
    resources AS (
      SELECT 'webhook'::text AS kind, id::text, tenant_id, agent_uid, session_id
      FROM signal_gateway_webhook_endpoints WHERE session_id LIKE 'job:%' OR session_id LIKE 'wf_task:%'
      UNION ALL
      SELECT 'automation'::text, id::text, tenant_id, agent_uid, owner_session_id
      FROM automation_jobs
      WHERE owner_session_id LIKE 'job:%' OR owner_session_id LIKE 'wf_task:%'
    ),
    owners AS (
      SELECT resources.*, NULL::jsonb AS reply_route, ARRAY[session_id] AS visited
      FROM resources
      UNION ALL
      SELECT owner.kind, owner.id, owner.tenant_id, owner.agent_uid,
             edge.owner_session_id, edge.reply_route, owner.visited || edge.owner_session_id
      FROM owners AS owner
      JOIN edges AS edge ON edge.tenant_id = owner.tenant_id AND edge.agent_uid = owner.agent_uid
                         AND edge.session_id = owner.session_id
      WHERE edge.owner_session_id <> '' AND NOT edge.owner_session_id = ANY(owner.visited)
    )
    SELECT owner.kind, owner.id, owner.tenant_id, owner.agent_uid,
           owner.session_id, owner.reply_route
    FROM owners AS owner
    WHERE owner.session_id NOT LIKE 'job:%' AND owner.session_id NOT LIKE 'wf_task:%'
      AND jsonb_typeof(owner.reply_route->'binding_name') = 'string'
      AND owner.reply_route->>'binding_name' <> ''
      AND EXISTS (
        SELECT 1 FROM ai_gateway_conversations AS conversation
        WHERE conversation.tenant_id = owner.tenant_id
          AND conversation.subject_uid = owner.agent_uid
          AND conversation.conversation_key = owner.session_id
      )
    """

    execute """
    UPDATE signal_gateway_webhook_endpoints AS endpoint
    SET session_id = owner.session_id,
        binding_name = owner.reply_route->>'binding_name',
        signal_channel_id = owner.reply_route->>'signal_channel_id',
        provider_thread_id = owner.reply_route->>'provider_thread_id'
    FROM b07_long_lived_owners AS owner
    WHERE owner.kind = 'webhook' AND owner.id = endpoint.id::text
      AND owner.tenant_id = endpoint.tenant_id AND owner.agent_uid = endpoint.agent_uid
    """

    execute """
    UPDATE automation_jobs AS job
    SET owner_session_id = owner.session_id, reply_route = owner.reply_route
    FROM b07_long_lived_owners AS owner
    WHERE owner.kind = 'automation' AND owner.id = job.id::text
      AND owner.tenant_id = job.tenant_id AND owner.agent_uid = job.agent_uid
    """

    execute """
    DO $$
    DECLARE unresolved record;
    BEGIN
      FOR unresolved IN
        SELECT 'webhook' AS kind, id::text AS id FROM signal_gateway_webhook_endpoints
        WHERE session_id LIKE 'job:%' OR session_id LIKE 'wf_task:%'
        UNION ALL
        SELECT 'automation', id::text FROM automation_jobs
        WHERE owner_session_id LIKE 'job:%' OR owner_session_id LIKE 'wf_task:%'
      LOOP
        RAISE NOTICE 'Preserved unresolved % owner: id %. Check its Job/Workflow and Conversation facts.',
                     unresolved.kind, unresolved.id;
      END LOOP;
    END $$;
    """
  end

  def down do
    raise Ecto.MigrationError,
          "Long-lived owners cannot be replaced with ended execution sessions. Restore the database backup."
  end
end
