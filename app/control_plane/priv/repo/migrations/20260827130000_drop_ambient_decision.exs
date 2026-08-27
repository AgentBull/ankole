defmodule Ankole.Repo.Migrations.DropAmbientDecision do
  use Ecto.Migration

  # The action router replaced the two-valued `decision`: `action` +
  # `authority` + `handoff_job_id` are the judgment. The backfill in
  # ExpandAmbientActions already gave every row an action, so the old column
  # and the constraints that reference it go.
  def up do
    drop constraint(
           :signal_gateway_ambient_judgments,
           :signal_gateway_ambient_judgments_action_contract_check
         )

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
  end

  def down do
    raise Ecto.MigrationError,
      message: "the dropped ambient decision column cannot be restored"
  end
end
