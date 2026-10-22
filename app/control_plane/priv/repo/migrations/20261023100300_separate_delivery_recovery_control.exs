defmodule Ankole.Repo.Migrations.SeparateDeliveryRecoveryControl do
  use Ecto.Migration

  def up do
    alter table(:deliveries) do
      add :recovery_status, :text
      add :recovery_reason, :text
      add :possible_duplicate, :boolean, null: false, default: false
      add :possible_duplicate_notice, :text
    end

    execute """
    UPDATE deliveries
    SET recovery_status = CASE
          WHEN status IN ('failed', 'unknown')
            AND (recovery_state->>'state') IN ('blocked', 'permanent', 'exhausted')
          THEN recovery_state->>'state'
        END,
        recovery_reason = CASE
          WHEN status IN ('failed', 'unknown')
            AND (recovery_state->>'state') IN ('blocked', 'permanent', 'exhausted')
          THEN COALESCE(NULLIF(btrim(recovery_state->>'reason'), ''),
                        NULLIF(btrim(last_error->>'code'), ''),
                        recovery_state->>'state')
        END,
        possible_duplicate = COALESCE((recovery_state->>'possible_duplicate')::boolean, false),
        possible_duplicate_notice = NULLIF(btrim(recovery_state->>'possible_duplicate_notice'), ''),
        recovery_state = COALESCE(recovery_state, '{}'::jsonb)
          - 'state' - 'reason' - 'possible_duplicate' - 'possible_duplicate_notice'
    """

    create constraint(:deliveries, :deliveries_recovery_status_valid,
             check: "recovery_status IN ('blocked', 'permanent', 'exhausted')"
           )

    create constraint(:deliveries, :deliveries_recovery_status_delivery,
             check: "recovery_status IS NULL OR status IN ('failed', 'unknown')"
           )

    create constraint(:deliveries, :deliveries_recovery_reason_paired,
             check:
               "(recovery_status IS NULL AND recovery_reason IS NULL) OR " <>
                 "(recovery_status IS NOT NULL AND recovery_reason IS NOT NULL AND btrim(recovery_reason) <> '')"
           )

    create constraint(:deliveries, :deliveries_duplicate_notice_requires_flag,
             check:
               "possible_duplicate_notice IS NULL OR " <>
                 "(possible_duplicate AND btrim(possible_duplicate_notice) <> '')"
           )

    create constraint(:deliveries, :deliveries_recovery_state_adapter_only,
             check:
               "NOT (recovery_state ?| ARRAY['state', 'reason', 'possible_duplicate', 'possible_duplicate_notice'])"
           )

    create index(:deliveries, [:tenant_id, :updated_at, :binding_name, :outbound_key],
             name: :deliveries_stopped_index,
             where:
               "delivery_class = 'durable_ai_reply' AND " <>
                 "(status = 'expired' OR (status IN ('failed', 'unknown') AND next_attempt_at IS NULL " <>
                 "AND (recovery_status IS NOT NULL OR possible_duplicate)))"
           )
  end

  def down do
    drop index(:deliveries, [], name: :deliveries_stopped_index)
    drop constraint(:deliveries, :deliveries_recovery_state_adapter_only)
    drop constraint(:deliveries, :deliveries_duplicate_notice_requires_flag)
    drop constraint(:deliveries, :deliveries_recovery_reason_paired)
    drop constraint(:deliveries, :deliveries_recovery_status_delivery)
    drop constraint(:deliveries, :deliveries_recovery_status_valid)

    execute """
    UPDATE deliveries
    SET recovery_state = recovery_state || jsonb_strip_nulls(jsonb_build_object(
      'state', recovery_status,
      'reason', recovery_reason,
      'possible_duplicate', CASE WHEN possible_duplicate THEN true END,
      'possible_duplicate_notice', possible_duplicate_notice
    ))
    """

    alter table(:deliveries) do
      remove :recovery_status
      remove :recovery_reason
      remove :possible_duplicate
      remove :possible_duplicate_notice
    end
  end
end
