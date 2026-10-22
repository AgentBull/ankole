defmodule Ankole.Repo.Migrations.MakeWorkflowWakeContractExplicit do
  use Ecto.Migration

  def up do
    drop constraint(:workflow_agent_calls, :workflow_agent_calls_sleeping_deadline_present)
    rename table(:workflow_agent_calls), :sleeping_until, to: :wake_at

    alter table(:workflow_agent_calls) do
      add :wake_kind, :text
      add :progress_at, :utc_datetime_usec
    end

    execute """
    UPDATE workflow_agent_calls
    SET wake_kind = CASE WHEN status = 'sleeping' THEN 'sleep' ELSE NULL END,
        wake_at = CASE WHEN status = 'sleeping' THEN wake_at ELSE NULL END,
        progress_at = CASE WHEN status = 'running' THEN updated_at ELSE NULL END
    """

    execute """
    UPDATE workflow_agent_calls AS call
    SET status = 'queued', wake_kind = 'agent_capacity', wake_at = signal.available_at
    FROM (
      SELECT tenant_id, agent_uid, session_id, min(available_at) AS available_at
      FROM signals
      WHERE input_state = 'open' AND completed_at IS NULL
        AND data->>'workflow_dispatch_deferred_reason' = 'agent_capacity'
      GROUP BY tenant_id, agent_uid, session_id
    ) AS signal
    WHERE call.status IN ('queued', 'sleeping') AND signal.tenant_id = call.tenant_id
      AND signal.agent_uid = call.agent_uid
      AND signal.session_id = 'wf_task:' || call.id::text
    """

    execute """
    UPDATE signals SET data = data - 'workflow_dispatch_deferred_reason'
    WHERE data ? 'workflow_dispatch_deferred_reason'
    """

    create constraint(:workflow_agent_calls, :workflow_agent_calls_wake_contract,
             check: """
             (status = 'sleeping' AND wake_kind IS NOT DISTINCT FROM 'sleep' AND wake_at IS NOT NULL)
             OR (status = 'queued' AND ((wake_kind IS NULL AND wake_at IS NULL)
                                       OR (wake_kind IS NOT DISTINCT FROM 'agent_capacity' AND wake_at IS NOT NULL)))
             OR (status IN ('running', 'succeeded', 'failed', 'cancelled')
                 AND wake_kind IS NULL AND wake_at IS NULL)
             """
           )
  end

  def down do
    drop constraint(:workflow_agent_calls, :workflow_agent_calls_wake_contract)

    alter table(:workflow_agent_calls) do
      remove :wake_kind
      remove :progress_at
    end

    rename table(:workflow_agent_calls), :wake_at, to: :sleeping_until

    create constraint(:workflow_agent_calls, :workflow_agent_calls_sleeping_deadline_present,
             check: "status <> 'sleeping' OR sleeping_until IS NOT NULL"
           )
  end
end
