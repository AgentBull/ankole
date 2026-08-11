defmodule Ankole.Repo.Migrations.BoundOutboxDeliveryRetries do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE signal_gateway_outbox_entries
    SET next_attempt_at = NULL,
        recovery_state =
          (COALESCE(recovery_state, '{}'::jsonb) - 'state' - 'reason') ||
          '{"state":"exhausted","reason":"max_attempts_reached"}'::jsonb
    WHERE status = 'failed'
      AND attempt_count >= max_attempts
      AND COALESCE(recovery_state->>'state', '') NOT IN ('blocked', 'permanent')
    """)

    execute("""
    UPDATE signal_gateway_outbox_entries
    SET next_attempt_at = NULL,
        recovery_state =
          (COALESCE(recovery_state, '{}'::jsonb) - 'state' - 'reason') ||
          '{"state":"blocked","reason":"legacy_ambiguous_delivery","possible_duplicate":true}'::jsonb
    WHERE status = 'unknown_after_send'
    """)
  end

  def down do
    execute("""
    UPDATE signal_gateway_outbox_entries
    SET recovery_state = recovery_state - 'state' - 'reason' - 'possible_duplicate'
    WHERE status = 'unknown_after_send'
      AND recovery_state->>'reason' = 'legacy_ambiguous_delivery'
    """)

    execute("""
    UPDATE signal_gateway_outbox_entries
    SET next_attempt_at =
          CASE
            WHEN delivery_class = 'durable_ai_reply' THEN NOW() + INTERVAL '15 minutes'
            ELSE NULL
          END,
        recovery_state = recovery_state - 'state' - 'reason'
    WHERE status = 'failed'
      AND recovery_state->>'state' = 'exhausted'
      AND recovery_state->>'reason' = 'max_attempts_reached'
    """)
  end
end
