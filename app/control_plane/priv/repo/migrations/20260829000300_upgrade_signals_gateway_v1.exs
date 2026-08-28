defmodule Ankole.Repo.Migrations.UpgradeSignalsGatewayV1 do
  use Ecto.Migration

  def up do
    alter table(:signal_gateway_bindings) do
      remove :confidential_memory
    end

    alter table(:signal_gateway_ambient_judgments) do
      add :action, :text
      add :authority, :text
      add :handoff_job_id, :bigint
    end

    execute("""
    UPDATE signal_gateway_ambient_judgments
    SET action = CASE decision
          WHEN 'silent' THEN 'NOOP'
          WHEN 'intervene' THEN 'FOREGROUND_REPLY'
        END,
        authority = 'NONE'
    """)

    drop constraint(
           :signal_gateway_ambient_judgments,
           :signal_gateway_ambient_judgments_decision_check
         )

    alter table(:signal_gateway_ambient_judgments) do
      remove :decision
      modify :action, :text, null: false
      modify :authority, :text, null: false
    end

    create constraint(
             :signal_gateway_ambient_judgments,
             :signal_gateway_ambient_judgments_action_contract_check,
             check: """
             action IN ('NOOP', 'FOREGROUND_REPLY', 'NEW_WORK', 'HANDOFF')
             AND authority IN ('NONE', 'EXPLICIT_REQUEST', 'STANDING_ORDER')
             AND (action = 'NEW_WORK' OR authority = 'NONE')
             AND ((action = 'HANDOFF') = (handoff_job_id IS NOT NULL))
             AND (handoff_job_id IS NULL OR handoff_job_id > 0)
             """
           )

    create index(
             :signal_gateway_outbox_entries,
             [:signal_channel_id, :target_source_entry_id],
             name: :signal_gateway_outbox_durable_reply_edit_target_index,
             where:
               "status = 'succeeded' AND delivery_class = 'durable_ai_reply' AND operation = 'edit' AND target_source_entry_id IS NOT NULL AND source_actor_event_id IS NOT NULL"
           )
  end

  def down do
    raise Ecto.MigrationError,
      message: "the pre-v1 SignalsGateway state cannot be restored after the v1 upgrade"
  end
end
