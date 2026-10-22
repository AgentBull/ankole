defmodule Ankole.Repo.Migrations.MakeWorkStateExplicit do
  use Ecto.Migration

  @authorized_work ~w(signals cron_schedules scheduled_events background_agent_jobs workflow_runs automation_jobs)a

  def up do
    alter table(:background_agent_jobs) do
      add :worker_wait_started_at, :utc_datetime_usec
    end

    alter table(:automation_job_runs) do
      add :worker_wait_started_at, :utc_datetime_usec
    end

    # The Workflow backfill reads the old Signal input state. Do it first.
    make_workflow_wake_explicit()
    make_signal_status_explicit()

    replace_cron_states("'active', 'paused', 'deleted', 'completed'")

    create(
      constraint(:cron_schedules, :cron_schedules_live_deadline_check,
        check: "status = 'active' OR next_fire_at IS NULL"
      )
    )

    replace_work_authorization("human_access_version IS NOT NULL AND ")

    create(
      constraint(:signal_webhook_endpoints, :signal_webhook_endpoints_lifecycle_check,
        check: """
        (status = 'fired' AND fired_at IS NOT NULL AND cancelled_at IS NULL)
        OR (status = 'cancelled' AND cancelled_at IS NOT NULL AND fired_at IS NULL)
        OR (status IN ('armed', 'active', 'expired') AND fired_at IS NULL AND cancelled_at IS NULL)
        """
      )
    )
  end

  def down do
    drop(constraint(:signal_webhook_endpoints, :signal_webhook_endpoints_lifecycle_check))
    replace_work_authorization("")
    drop(constraint(:cron_schedules, :cron_schedules_live_deadline_check))
    replace_cron_states("'active', 'paused', 'deleted', 'failed', 'completed'")
    restore_signal_input_state()
    restore_workflow_sleep_deadline()

    alter table(:automation_job_runs) do
      remove :worker_wait_started_at
    end

    alter table(:background_agent_jobs) do
      remove :worker_wait_started_at
    end
  end

  defp make_workflow_wake_explicit do
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

  defp restore_workflow_sleep_deadline do
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

  defp make_signal_status_explicit do
    alter table(:signals) do
      add(:status, :text)
    end

    # Retained deadlines distinguish a deferred attempt from an admitted one.
    # Do not use the migration clock or discard conflicting terminal evidence.
    execute("""
    UPDATE signals SET status = CASE
      WHEN input_state = 'dead_letter' THEN 'dead_letter'
      WHEN completed_at IS NOT NULL THEN 'completed'
      WHEN last_attempt_at IS NOT NULL AND available_at <= last_attempt_at THEN 'running'
      ELSE 'queued'
    END
    """)

    alter table(:signals) do
      modify(:status, :text, null: false, default: "queued")
    end

    create(
      constraint(:signals, :signals_status_check,
        check: "status IN ('queued', 'running', 'completed', 'dead_letter')"
      )
    )

    create(
      constraint(:signals, :signals_lifecycle_check,
        check: """
        (status = 'completed' AND completed_at IS NOT NULL
          AND dead_letter_at IS NULL AND dead_letter_reason IS NULL)
        OR (status = 'dead_letter' AND completed_at IS NULL
          AND dead_letter_at IS NOT NULL AND dead_letter_reason IS NOT NULL
          AND jsonb_typeof(dead_letter_reason) = 'object')
        OR (status IN ('queued', 'running') AND completed_at IS NULL
          AND dead_letter_at IS NULL AND dead_letter_reason IS NULL
          AND (status != 'running' OR last_attempt_at IS NOT NULL))
        """
      )
    )

    alter table(:signals) do
      remove(:input_state)
    end

    create(
      index(:signals, [:tenant_id, :agent_uid, :session_id, :available_at, :queue_sequence],
        name: :signals_ready_index,
        where: "status IN ('queued', 'running')"
      )
    )
  end

  defp restore_signal_input_state do
    drop(
      index(:signals, [:tenant_id, :agent_uid, :session_id, :available_at, :queue_sequence],
        name: :signals_ready_index
      )
    )

    alter table(:signals) do
      add(:input_state, :text, null: false, default: "open")
    end

    execute("UPDATE signals SET input_state = 'dead_letter' WHERE status = 'dead_letter'")

    drop(constraint(:signals, :signals_lifecycle_check))
    drop(constraint(:signals, :signals_status_check))

    alter table(:signals) do
      remove(:status)
    end

    create(
      constraint(:signals, :signals_input_state_check,
        check: "input_state IN ('open', 'dead_letter')"
      )
    )

    execute(
      "COMMENT ON COLUMN signals.input_state IS 'Queue state for open or dead-lettered events.'"
    )

    create(
      index(:signals, [:tenant_id, :agent_uid, :session_id, :available_at, :queue_sequence],
        name: :signals_ready_index,
        where: "input_state = 'open' AND completed_at IS NULL"
      )
    )
  end

  defp replace_cron_states(states) do
    drop(constraint(:cron_schedules, :cron_schedules_status_check))

    create(
      constraint(:cron_schedules, :cron_schedules_status_check, check: "status IN (#{states})")
    )
  end

  defp replace_work_authorization(version_presence) do
    for table <- @authorized_work do
      name = "#{table}_work_authorization_check"
      drop(constraint(table, name))

      create(
        constraint(table, name,
          check: """
          (authorization_kind = 'human' AND human_uid IS NOT NULL
            AND #{version_presence}human_access_version > 0)
          OR (authorization_kind IN ('service', 'review_required')
            AND human_uid IS NULL AND human_access_version IS NULL)
          """
        )
      )
    end
  end
end
