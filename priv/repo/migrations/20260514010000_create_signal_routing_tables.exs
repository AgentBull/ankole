defmodule BullX.Repo.Migrations.CreateSignalRoutingTables do
  use Ecto.Migration

  def change do
    execute(
      "CREATE TYPE signal_route_action AS ENUM ('deliver_agent', 'drop_signal')",
      "DROP TYPE signal_route_action"
    )

    execute(
      "CREATE TYPE signal_sink_kind AS ENUM ('blackhole')",
      "DROP TYPE signal_sink_kind"
    )

    create table(:signal_route_rules, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :key, :text, null: false
      add :name, :text, null: false
      add :description, :text
      add :enabled, :boolean, null: false, default: true
      add :priority, :integer, null: false, default: 0
      add :signal_type, :text, null: false
      add :adapter, :text
      add :channel_id, :text
      add :scope_id, :text
      add :thread_id, :text
      add :actor_external_id, :text
      add :actor_bot, :boolean
      add :event_type, :text
      add :event_name, :text
      add :routing_fact_key, :text
      add :routing_fact_value, :text
      add :route_action, :signal_route_action, null: false
      add :agent_principal_id, references(:agents, column: :principal_id, type: :uuid)
      add :sink_kind, :signal_sink_kind
      add :reason, :text, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:signal_route_rules, [:key])
    create index(:signal_route_rules, [:enabled, :priority, :key])
    create index(:signal_route_rules, [:agent_principal_id])

    create constraint(:signal_route_rules, :signal_route_rules_key_format,
             check: "key ~ '^[a-z][a-z0-9_-]{0,62}$'"
           )

    create constraint(:signal_route_rules, :signal_route_rules_priority_range,
             check: "priority >= 0 AND priority <= 100"
           )

    create constraint(:signal_route_rules, :signal_route_rules_signal_type_required,
             check: "signal_type IS NOT NULL"
           )

    create constraint(:signal_route_rules, :signal_route_rules_routing_fact_pair,
             check: "(routing_fact_key IS NULL) = (routing_fact_value IS NULL)"
           )

    create constraint(:signal_route_rules, :signal_route_rules_routing_fact_key_format,
             check: "routing_fact_key IS NULL OR routing_fact_key ~ '^[a-z][a-z0-9_.:-]{0,127}$'"
           )

    create constraint(:signal_route_rules, :signal_route_rules_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    create constraint(:signal_route_rules, :signal_route_rules_reason_format,
             check: "reason ~ '^[a-z][a-z0-9_.:-]{0,127}$'"
           )

    create constraint(:signal_route_rules, :signal_route_rules_target_combination,
             check: """
             (
               route_action = 'deliver_agent' AND
               agent_principal_id IS NOT NULL AND
               sink_kind IS NULL
             ) OR (
               route_action = 'drop_signal' AND
               agent_principal_id IS NULL AND
               sink_kind = 'blackhole'
             )
             """
           )

    create constraint(:signal_route_rules, :signal_route_rules_non_broad_match,
             check: """
             (
               adapter IS NOT NULL OR
               channel_id IS NOT NULL OR
               scope_id IS NOT NULL OR
               thread_id IS NOT NULL OR
               actor_external_id IS NOT NULL OR
               actor_bot IS NOT NULL OR
               event_type IS NOT NULL OR
               event_name IS NOT NULL OR
               routing_fact_key IS NOT NULL
             ) OR (
               signal_type = 'com.agentbull.x.inbound.received' AND
               route_action = 'deliver_agent'
             )
             """
           )

    create table(:signal_route_decisions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :delivery_key, :text, null: false
      add :signal_occurrence_key, :text, null: false
      add :signal_id, :uuid, null: false
      add :signal_type, :text, null: false
      add :signal_time, :utc_datetime_usec, null: false
      add :adapter, :text
      add :channel_id, :text
      add :scope_id, :text
      add :thread_id, :text
      add :event_type, :text
      add :event_name, :text
      add :actor_bot, :boolean
      add :external_actor, :map, null: false, default: %{}
      add :destination_key, :text, null: false
      add :route_action, :signal_route_action, null: false
      add :agent_principal_id, references(:agents, column: :principal_id, type: :uuid)
      add :sink_kind, :signal_sink_kind
      add :rule_id, references(:signal_route_rules, type: :uuid, on_delete: :nilify_all)
      add :rule_key, :text, null: false
      add :reason, :text, null: false
      add :routing_snapshot, :map, null: false
      add :content_snapshot, :map
      add :decision_metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:signal_route_decisions, [:signal_id, :destination_key])
    create index(:signal_route_decisions, [:signal_occurrence_key, :destination_key])
    create index(:signal_route_decisions, [:delivery_key])

    create index(:signal_route_decisions, [:agent_principal_id, :inserted_at],
             where: "agent_principal_id IS NOT NULL"
           )

    create index(:signal_route_decisions, [:sink_kind, :inserted_at],
             where: "sink_kind IS NOT NULL"
           )

    create constraint(:signal_route_decisions, :signal_route_decisions_external_actor_object,
             check: "jsonb_typeof(external_actor) = 'object'"
           )

    create constraint(:signal_route_decisions, :signal_route_decisions_routing_snapshot_object,
             check: "jsonb_typeof(routing_snapshot) = 'object'"
           )

    create constraint(:signal_route_decisions, :signal_route_decisions_content_snapshot_object,
             check: "content_snapshot IS NULL OR jsonb_typeof(content_snapshot) = 'object'"
           )

    create constraint(:signal_route_decisions, :signal_route_decisions_metadata_object,
             check: "jsonb_typeof(decision_metadata) = 'object'"
           )

    create constraint(:signal_route_decisions, :signal_route_decisions_destination_key_format,
             check: "destination_key ~ '^[a-z][a-z0-9_:-]{0,190}$'"
           )

    create constraint(:signal_route_decisions, :signal_route_decisions_reason_format,
             check: "reason ~ '^[a-z][a-z0-9_.:-]{0,127}$'"
           )

    create constraint(:signal_route_decisions, :signal_route_decisions_target_combination,
             check: """
             (
               route_action = 'deliver_agent' AND
               agent_principal_id IS NOT NULL AND
               sink_kind IS NULL
             ) OR (
               route_action = 'drop_signal' AND
               agent_principal_id IS NULL AND
               sink_kind = 'blackhole'
             )
             """
           )

    create constraint(:signal_route_decisions, :signal_route_decisions_sink_has_no_content,
             check: "route_action = 'deliver_agent' OR content_snapshot IS NULL"
           )
  end
end
