defmodule Ankole.Repo.Migrations.RecordSilentActorTurnOutcome do
  use Ecto.Migration

  @turn_outcome_check "turn_outcome IS NULL OR turn_outcome IN ('loop_finished', 'iteration_exhausted', 'silent')"

  @completion_anchor_check """
  (final_response_id IS NULL AND turn_outcome IS NULL)
  OR (final_response_id IS NULL AND turn_outcome = 'silent' AND completed_at IS NOT NULL)
  OR (final_response_id IS NOT NULL AND final_response_id LIKE 'resp_%'
      AND turn_outcome IS NOT NULL AND completed_at IS NOT NULL)
  """

  def up do
    drop constraint(:actor_events, :actor_events_turn_outcome_check)
    drop constraint(:actor_events, :actor_events_completion_anchor_check)

    create constraint(:actor_events, :actor_events_turn_outcome_check, check: @turn_outcome_check)

    create constraint(:actor_events, :actor_events_completion_anchor_check,
             check: @completion_anchor_check
           )
  end

  def down do
    execute("""
    UPDATE actor_events
    SET turn_outcome = NULL, final_response_id = NULL
    WHERE turn_outcome = 'silent'
    """)

    drop constraint(:actor_events, :actor_events_turn_outcome_check)
    drop constraint(:actor_events, :actor_events_completion_anchor_check)

    create constraint(:actor_events, :actor_events_turn_outcome_check,
             check:
               "turn_outcome IS NULL OR turn_outcome IN ('loop_finished', 'iteration_exhausted')"
           )

    create constraint(:actor_events, :actor_events_completion_anchor_check,
             check: """
             (final_response_id IS NULL AND turn_outcome IS NULL)
             OR (final_response_id IS NOT NULL AND final_response_id LIKE 'resp_%'
                 AND turn_outcome IS NOT NULL AND completed_at IS NOT NULL)
             """
           )
  end
end
