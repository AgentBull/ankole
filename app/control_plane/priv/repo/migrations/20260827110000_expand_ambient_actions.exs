defmodule Ankole.Repo.Migrations.ExpandAmbientActions do
  use Ecto.Migration

  def up do
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
    WHERE action IS NULL
    """)

    create constraint(
             :signal_gateway_ambient_judgments,
             :signal_gateway_ambient_judgments_action_contract_check,
             check: """
             (action IS NULL AND authority IS NULL AND handoff_job_id IS NULL)
             OR
             (
               action IN ('NOOP', 'FOREGROUND_REPLY', 'NEW_WORK', 'HANDOFF')
               AND authority IN ('NONE', 'EXPLICIT_REQUEST', 'STANDING_ORDER')
               AND (
                 (action IN ('FOREGROUND_REPLY', 'NEW_WORK') AND decision = 'intervene')
                 OR (action IN ('NOOP', 'HANDOFF') AND decision = 'silent')
               )
               AND (action = 'NEW_WORK' OR authority = 'NONE')
               AND ((action = 'HANDOFF') = (handoff_job_id IS NOT NULL))
               AND (handoff_job_id IS NULL OR handoff_job_id > 0)
             )
             """
           )
  end

  def down do
    drop constraint(
           :signal_gateway_ambient_judgments,
           :signal_gateway_ambient_judgments_action_contract_check
         )

    alter table(:signal_gateway_ambient_judgments) do
      remove :handoff_job_id
      remove :authority
      remove :action
    end
  end
end
