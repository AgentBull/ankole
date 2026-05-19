defmodule BullX.Repo.Migrations.CreateEventbusTables do
  use Ecto.Migration

  def change do
    execute(
      "CREATE TYPE eventbus_target_type AS ENUM ('ai_agent', 'workflow', 'command', 'external_agent_harness', 'blackhole')",
      "DROP TYPE eventbus_target_type"
    )

    execute(
      "CREATE TYPE target_session_status AS ENUM ('active', 'closed', 'failed', 'expired')",
      "DROP TYPE target_session_status"
    )

    execute(
      "CREATE TYPE target_session_window_type AS ENUM ('new_per_event', 'rolling_ttl')",
      "DROP TYPE target_session_window_type"
    )

    create table(:event_routing_rules, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :text, null: false
      add :active, :boolean, null: false, default: true
      add :priority, :integer, null: false
      add :match_expr, :text, null: false
      add :target_type, :eventbus_target_type, null: false
      add :target_ref, :text
      add :scope_fields, {:array, :text}, null: false, default: []
      add :window_type, :target_session_window_type, null: false
      add :window_ttl_seconds, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:event_routing_rules, [:priority])
    create unique_index(:event_routing_rules, [:name])

    create constraint(:event_routing_rules, :event_routing_rules_name_trimmed_non_empty,
             check: "name = btrim(name) AND name <> ''"
           )

    create constraint(:event_routing_rules, :event_routing_rules_priority_positive,
             check: "priority > 0"
           )

    create constraint(:event_routing_rules, :event_routing_rules_blackhole_target_ref,
             check:
               "(target_type = 'blackhole' AND target_ref IS NULL) OR (target_type <> 'blackhole' AND target_ref IS NOT NULL)"
           )

    create constraint(:event_routing_rules, :event_routing_rules_rolling_ttl_seconds,
             check:
               "(window_type = 'rolling_ttl' AND window_ttl_seconds IS NOT NULL AND window_ttl_seconds > 0) OR (window_type = 'new_per_event' AND window_ttl_seconds IS NULL)"
           )

    create table(:target_sessions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :event_routing_rule_id, :uuid, null: false
      add :target_type, :eventbus_target_type, null: false
      add :target_ref, :text, null: false
      add :scope_key, :text, null: false
      add :window_key, :text, null: false
      add :status, :target_session_status, null: false
      add :oban_job_id, :bigint
      add :last_processed_entry_seq, :bigint, null: false, default: 0
      add :expires_at, :utc_datetime_usec
      add :terminal_reason, :text

      timestamps(type: :utc_datetime_usec)
    end

    execute("ALTER TABLE target_sessions SET UNLOGGED", "ALTER TABLE target_sessions SET LOGGED")

    create unique_index(
             :target_sessions,
             [:event_routing_rule_id, :target_type, :target_ref, :scope_key, :window_key],
             where: "status = 'active'",
             name: :target_sessions_active_reuse_key_index
           )

    create index(:target_sessions, [:expires_at])
    create index(:target_sessions, [:oban_job_id])

    create table(:target_session_entries, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :entry_seq, :bigserial, null: false
      add :target_session_id, :uuid, null: false
      add :event_source, :text, null: false
      add :event_id, :text, null: false
      add :dedupe_hash, :text, null: false
      add :cloud_event, :map, null: false
      add :routing_context, :map, null: false
      add :appended_at, :utc_datetime_usec, null: false
    end

    execute(
      "ALTER TABLE target_session_entries SET UNLOGGED",
      "ALTER TABLE target_session_entries SET LOGGED"
    )

    create unique_index(:target_session_entries, [:dedupe_hash])
    create index(:target_session_entries, [:target_session_id, :entry_seq])
  end
end
