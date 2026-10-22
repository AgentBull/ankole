defmodule Ankole.Repo.Migrations.MakeSignalQueueStateExplicit do
  use Ecto.Migration

  def up do
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

  def down do
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

    create(
      index(:signals, [:agent_uid, :session_id, :available_at, :queue_sequence],
        name: :signals_ready_index,
        where: "input_state = 'open' AND completed_at IS NULL"
      )
    )
  end
end
