defmodule Ankole.Repo.Migrations.ConstrainDomainFacts do
  use Ecto.Migration

  @pod_versioned_tables [:db_fields, :db_views]

  def up do
    create constraint(:db_tables, :db_tables_counters,
             check: "data_version >= 0 AND record_count >= 0 AND next_auto_number > 0"
           )

    for table <- @pod_versioned_tables do
      create constraint(table, :"#{table}_version", check: "version > 0")

      create constraint(table, :"#{table}_config_object",
               check: "jsonb_typeof(config) = 'object'"
             )
    end

    create constraint(:db_records, :db_records_value_objects,
             check: "jsonb_typeof(data) = 'object' AND jsonb_typeof(versions) = 'object'"
           )

    create constraint(:conversation_inbound_batches, :inbound_batches_revision_non_negative,
             check: "batch_revision >= 0"
           )

    create constraint(:brain_schema_types, :brain_schema_types_subtypes_strings,
             check:
               ~s|jsonb_typeof(subtypes) = 'array' AND NOT jsonb_path_exists(subtypes, '$[*] ? (@.type() != "string")')|
           )

    # The tenant foreign key migration also uses this parent key.
    create unique_index(:brain_claims, [:tenant_id, :id])

    execute(
      "ALTER TABLE brain_take_domain_assignments DROP CONSTRAINT brain_take_domain_assignments_take_claim_id_fkey"
    )

    execute(
      "ALTER TABLE brain_take_domain_assignments ADD CONSTRAINT brain_take_domain_assignments_take_claim_id_fkey FOREIGN KEY (tenant_id, take_claim_id) REFERENCES brain_claims(tenant_id, id) ON DELETE CASCADE"
    )

    execute("""
    ALTER TABLE conversation_messages
      ALTER CONSTRAINT conversation_messages_signal_id_fkey
      DEFERRABLE INITIALLY DEFERRED
    """)

    replace_claim_shape("notability IS NOT NULL AND")

    create constraint(:session_round_states, :session_round_states_pages_object,
             check: "jsonb_typeof(pages) = 'object'"
           )

    create constraint(:session_round_states, :session_round_states_results_object,
             check: "jsonb_typeof(results) = 'object'"
           )
  end

  def down do
    drop constraint(:session_round_states, :session_round_states_results_object)
    drop constraint(:session_round_states, :session_round_states_pages_object)

    replace_claim_shape("")

    execute("""
    ALTER TABLE conversation_messages
      ALTER CONSTRAINT conversation_messages_signal_id_fkey
      NOT DEFERRABLE INITIALLY IMMEDIATE
    """)

    execute(
      "ALTER TABLE brain_take_domain_assignments DROP CONSTRAINT brain_take_domain_assignments_take_claim_id_fkey"
    )

    execute(
      "ALTER TABLE brain_take_domain_assignments ADD CONSTRAINT brain_take_domain_assignments_take_claim_id_fkey FOREIGN KEY (take_claim_id) REFERENCES brain_claims(id) ON DELETE CASCADE"
    )

    drop index(:brain_claims, [:tenant_id, :id])
    drop constraint(:brain_schema_types, :brain_schema_types_subtypes_strings)

    drop constraint(:conversation_inbound_batches, :inbound_batches_revision_non_negative)

    drop constraint(:db_records, :db_records_value_objects)

    for table <- Enum.reverse(@pod_versioned_tables) do
      drop constraint(table, :"#{table}_config_object")
      drop constraint(table, :"#{table}_version")
    end

    drop constraint(:db_tables, :db_tables_counters)
  end

  defp replace_claim_shape(notability) do
    execute("ALTER TABLE brain_claims DROP CONSTRAINT brain_claims_type_shape")

    execute("""
    ALTER TABLE brain_claims ADD CONSTRAINT brain_claims_type_shape CHECK (
      (claim_type = 'fact'
        AND kind IN ('event', 'preference', 'commitment', 'belief', 'fact')
        AND #{notability} notability IN ('high', 'medium', 'low')
        AND valid_from IS NOT NULL
        AND confidence IS NOT NULL AND confidence >= 0 AND confidence <= 1
        AND num_nonnulls(weight, since_date, until_date, active, graded_quality,
          graded_confidence, graded_at, resolved_at, resolved_outcome, resolved_quality,
          resolved_value, resolved_unit, resolution_provenance, resolved_by) = 0)
      OR
      (claim_type = 'take'
        AND weight IS NOT NULL AND weight >= 0 AND weight <= 1
        AND active IS NOT NULL
        AND num_nonnulls(notability, context, valid_from, valid_until, expired_at,
          consolidated_at, consolidated_into, confidence) = 0)
    )
    """)
  end
end
