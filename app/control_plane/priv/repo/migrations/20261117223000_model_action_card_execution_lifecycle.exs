defmodule Ankole.Repo.Migrations.ModelActionCardExecutionLifecycle do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE conversation_action_cards
      ADD COLUMN execution_claim_id uuid,
      ADD COLUMN execution_claim_expires_at timestamptz,
      ADD COLUMN execution_attempts integer NOT NULL DEFAULT 0,
      DROP CONSTRAINT conversation_action_cards_status_check,
      DROP CONSTRAINT conversation_action_cards_resolution_shape
    """)

    execute("""
    UPDATE conversation_action_cards
    SET
      status = 'executing',
      execution_claim_id = (preconditions #>> '{execution_claim,claim_id}')::uuid,
      execution_claim_expires_at = (preconditions #>> '{execution_claim,expires_at}')::timestamptz,
      execution_attempts = CASE
        WHEN (preconditions #>> '{execution_claim,recover_settled}') = 'true' THEN 2
        ELSE 1
      END,
      resolved_by_uid = COALESCE(resolved_by_uid, preconditions #>> '{execution_claim,claimed_by_uid}'),
      preconditions = preconditions - 'execution_claim'
    WHERE status = 'prepared'
      AND preconditions ? 'execution_claim'
      AND (preconditions #>> '{execution_claim,claim_id}') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      AND NULLIF(preconditions #>> '{execution_claim,expires_at}', '') IS NOT NULL
    """)

    execute("""
    UPDATE conversation_action_cards
    SET preconditions = preconditions - 'execution_claim'
    WHERE preconditions ? 'execution_claim'
    """)

    execute("""
    ALTER TABLE conversation_action_cards
      ADD CONSTRAINT conversation_action_cards_status_check
        CHECK (status IN ('prepared', 'executing', 'executed', 'execution_uncertain', 'failed', 'stale', 'cancelled')),
      ADD CONSTRAINT conversation_action_cards_execution_attempts_check
        CHECK (execution_attempts >= 0),
      ADD CONSTRAINT conversation_action_cards_resolution_shape
        CHECK (
          (status = 'prepared' AND resolved_at IS NULL AND execution_claim_id IS NULL AND execution_claim_expires_at IS NULL AND execution_attempts = 0)
          OR (status = 'executing' AND resolved_at IS NULL AND execution_claim_id IS NOT NULL AND execution_claim_expires_at IS NOT NULL AND execution_attempts >= 1)
          OR (status IN ('executed', 'execution_uncertain', 'failed', 'stale', 'cancelled') AND resolved_at IS NOT NULL AND execution_claim_id IS NULL AND execution_claim_expires_at IS NULL)
        )
    """)
  end

  def down do
    execute("""
    ALTER TABLE conversation_action_cards
      DROP CONSTRAINT conversation_action_cards_resolution_shape,
      DROP CONSTRAINT conversation_action_cards_execution_attempts_check,
      DROP CONSTRAINT conversation_action_cards_status_check
    """)

    execute("""
    UPDATE conversation_action_cards
    SET
      preconditions = jsonb_set(
        preconditions,
        '{execution_claim}',
        jsonb_build_object(
          'claim_id', execution_claim_id::text,
          'recover_settled', execution_attempts > 1,
          'claimed_by_uid', resolved_by_uid,
          'expires_at', to_char(execution_claim_expires_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
        )
      ),
      status = 'prepared',
      resolved_by_uid = NULL,
      resolved_by_name = NULL
    WHERE status = 'executing'
    """)

    execute("""
    UPDATE conversation_action_cards
    SET status = 'executed'
    WHERE status IN ('execution_uncertain', 'failed')
    """)

    execute("""
    ALTER TABLE conversation_action_cards
      DROP COLUMN execution_claim_id,
      DROP COLUMN execution_claim_expires_at,
      DROP COLUMN execution_attempts,
      ADD CONSTRAINT conversation_action_cards_status_check
        CHECK (status IN ('prepared', 'executed', 'stale', 'cancelled')),
      ADD CONSTRAINT conversation_action_cards_resolution_shape
        CHECK ((status = 'prepared' AND resolved_at IS NULL) OR (status <> 'prepared' AND resolved_at IS NOT NULL))
    """)
  end
end
