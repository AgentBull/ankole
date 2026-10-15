Code.require_file("../migration_support/signal_producers.exs", __DIR__)

defmodule Ankole.Repo.Migrations.UnifySignalsAndSessions do
  use Ecto.Migration

  def up do
    rename(table(:actor_events), to: table(:signals))
    rename(table(:actor_session_workspaces), to: table(:sessions))
    rename(table(:actor_cron_schedules), to: table(:cron_schedules))
    rename(table(:actor_scheduled_events), to: table(:scheduled_events))

    alter table(:signals) do
      add(:producer, :text, default: "external", null: false)
      add(:reply_binding_name, :text)
      add(:subject, :text)
      add(:occurred_at, :utc_datetime_usec)
      add(:message_id, :uuid)
      add(:extensions, :map, default: %{}, null: false)
    end

    create(
      constraint(:signals, :signals_producer_check, check: "producer IN ('kernel','external')")
    )

    execute("""
    UPDATE signals AS s
    SET reply_binding_name = CASE WHEN EXISTS (
          SELECT 1 FROM signal_gateway_bindings b
          WHERE b.tenant_id = s.tenant_id AND b.agent_uid = s.agent_uid AND b.name = s.binding_name
        ) THEN s.binding_name END,
        subject = NULLIF(s.payload->>'subject', ''),
        occurred_at = COALESCE(NULLIF(s.payload->>'time', '')::timestamptz AT TIME ZONE 'UTC', s.inserted_at),
        message_id = CASE WHEN s.type = 'conversation.message.addressed'
          AND (s.payload->'data'->>'message_id') ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
          THEN (s.payload->'data'->>'message_id')::uuid END
    """)

    drop(
      index(:signals, [:agent_uid, :binding_name, :source_event_id],
        name: :actor_events_signal_idempotency_index
      )
    )

    drop(
      index(:signals, [:agent_uid, :session_id, :queue_sequence],
        name: :actor_events_queue_sequence_index
      )
    )

    rename(table(:signals), :binding_name, to: :source)
    rename(table(:signals), :payload, to: :data)

    execute("""
    UPDATE signals
    SET source = COALESCE(NULLIF(data->>'source', ''), 'urn:ankole:' || type || ':' || session_id),
        data = COALESCE(data->'data', '{}'::jsonb)
    """)

    alter table(:signals) do
      modify(:subject, :text, null: true)
      modify(:occurred_at, :utc_datetime_usec, null: false)
      modify(:data, :map, null: true)
    end

    drop(constraint(:signals, :actor_events_payload_object))

    execute("""
    DO $$
    DECLARE conflict record;
    BEGIN
      SELECT tenant_id, agent_uid, source, source_event_id, array_agg(id ORDER BY id) AS signal_ids
      INTO conflict FROM signals
      GROUP BY tenant_id, agent_uid, source, source_event_id HAVING count(*) > 1 LIMIT 1;
      IF FOUND THEN
        RAISE EXCEPTION 'Signal identity conflict: tenant %, Agent %, source %, event %, Signals %',
          conflict.tenant_id, conflict.agent_uid, conflict.source, conflict.source_event_id, conflict.signal_ids;
      END IF;
    END $$;
    """)

    create(
      unique_index(:signals, [:tenant_id, :agent_uid, :source, :source_event_id],
        name: :signals_signal_idempotency_index
      )
    )

    create(
      unique_index(:signals, [:tenant_id, :agent_uid, :session_id, :queue_sequence],
        name: :signals_queue_sequence_index
      )
    )

    execute("""
    ALTER TABLE signals ADD CONSTRAINT signals_message_id_fkey
    FOREIGN KEY (tenant_id, message_id) REFERENCES conversation_messages (tenant_id, id)
    ON DELETE SET NULL (message_id)
    """)

    alter table(:sessions) do
      add(
        :conversation_id,
        references(:conversations,
          type: :uuid,
          with: [tenant_id: :tenant_id],
          on_delete: :delete_all
        )
      )
    end

    execute("""
    UPDATE sessions AS s SET conversation_id = c.id
    FROM conversations c
    WHERE c.tenant_id = s.tenant_id AND s.session_id = 'conversation:' || c.id::text
    """)

    alter table(:cron_schedules) do
      modify(:binding_name, :text, null: true)
    end

    alter table(:scheduled_events) do
      modify(:binding_name, :text, null: true)
    end

    alter table(:signal_gateway_webhook_endpoints) do
      modify(:binding_name, :text, null: true)
    end

    drop(constraint(:conversation_messages, :conversation_messages_provenance_check))

    create(
      constraint(:conversation_messages, :conversation_messages_provenance_check,
        check:
          "(author_type = 'human' AND signal_id IS NULL AND session_id IS NULL) OR " <>
            "(author_type = 'agent' AND signal_id IS NOT NULL AND session_id IS NOT NULL AND btrim(session_id) <> '')"
      )
    )

    drop(
      index(:conversation_messages, [:tenant_id, :signal_id],
        name: :conversation_messages_signal_index
      )
    )

    create(
      unique_index(:conversation_messages, [:tenant_id, :conversation_id, :signal_id],
        name: :conversation_messages_signal_index,
        where: "signal_id IS NOT NULL"
      )
    )

    rename_stored_columns()
    rename_stored_constraints()
    migrate_runtime_references()
    execute(fn -> Ankole.Repo.Migrations.SignalProducers.backfill(repo()) end)

    execute(
      "UPDATE oban_jobs SET worker = 'Ankole.AgentWorkers.SweepJob' WHERE worker = 'Ankole.SignalsGateway.ActorRuntime.AgentWorkers.SweepJob'"
    )

    execute(
      "UPDATE oban_jobs SET worker = 'Ankole.AgentWorkers.ReconcileJob' WHERE worker = 'Ankole.SignalsGateway.ActorRuntime.AgentWorkers.ReconcileJob'"
    )

    execute(
      "UPDATE oban_jobs SET worker = 'Ankole.AgentWorkers.PrepareImageJob' WHERE worker = 'Ankole.SignalsGateway.ActorRuntime.AgentWorkers.PrepareImageJob'"
    )

    execute(
      "UPDATE oban_jobs SET worker = 'Ankole.Sessions.Jobs.EnqueueDailySessionResets' WHERE worker = 'Ankole.SignalsGateway.ActorRuntime.Jobs.EnqueueDailySessionResets'"
    )

    execute(
      "UPDATE oban_jobs SET worker = 'Ankole.Sessions.Jobs.FireScheduledEvent' WHERE worker = 'Ankole.SignalsGateway.ActorRuntime.Jobs.FireScheduledEvent'"
    )
  end

  defp rename_stored_columns do
    execute("""
    DO $$
    DECLARE col record;
    BEGIN
      FOR col IN SELECT table_name, column_name FROM information_schema.columns
        WHERE table_schema = 'public' AND column_name LIKE '%actor_event%'
      LOOP
        EXECUTE format('ALTER TABLE %I RENAME COLUMN %I TO %I', col.table_name, col.column_name,
          replace(col.column_name, 'actor_event', 'signal'));
      END LOOP;
    END $$
    """)
  end

  defp rename_stored_constraints do
    execute("""
    DO $$
    DECLARE item record; current_name text;
    BEGIN
      FOR item IN SELECT conrelid::regclass AS table_name, conname FROM pg_constraint
        WHERE connamespace = 'public'::regnamespace AND conname LIKE '%actor_%'
      LOOP
        current_name := replace(replace(replace(replace(replace(item.conname,
          'actor_session_workspaces', 'sessions'), 'actor_cron_schedules', 'cron_schedules'),
          'actor_scheduled_events', 'scheduled_events'), 'actor_events', 'signals'), 'actor_event', 'signal');
        IF current_name <> item.conname THEN
          EXECUTE format('ALTER TABLE %s RENAME CONSTRAINT %I TO %I', item.table_name, item.conname, current_name);
        END IF;
      END LOOP;
      FOR item IN SELECT indexname FROM pg_indexes WHERE schemaname = 'public' AND indexname LIKE '%actor_%'
      LOOP
        current_name := replace(replace(replace(replace(replace(item.indexname,
          'actor_session_workspaces', 'sessions'), 'actor_cron_schedules', 'cron_schedules'),
          'actor_scheduled_events', 'scheduled_events'), 'actor_events', 'signals'), 'actor_event', 'signal');
        IF current_name <> item.indexname THEN
          EXECUTE format('ALTER INDEX %I RENAME TO %I', item.indexname, current_name);
        END IF;
      END LOOP;
      ALTER INDEX sessions_actor_index RENAME TO sessions_session_index;
    END $$
    """)
  end

  defp migrate_runtime_references do
    execute("""
    CREATE FUNCTION pg_temp.rename_runtime_references(value jsonb) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE STRICT AS $$
    DECLARE result jsonb; key text; item jsonb;
    BEGIN
      IF jsonb_typeof(value) = 'object' THEN
        result := '{}'::jsonb;
        FOR key, item IN SELECT * FROM jsonb_each(value) LOOP
          result := result || jsonb_build_object(replace(replace(key, 'actor_event', 'signal'), 'ActorEvent', 'Signal'), pg_temp.rename_runtime_references(item));
        END LOOP;
        RETURN result;
      ELSIF jsonb_typeof(value) = 'array' THEN
        SELECT COALESCE(jsonb_agg(pg_temp.rename_runtime_references(element) ORDER BY ordinal), '[]'::jsonb)
        INTO result FROM jsonb_array_elements(value) WITH ORDINALITY AS arr(element, ordinal);
        RETURN result;
      ELSIF value = '"actor_event"'::jsonb THEN
        RETURN '"signal"'::jsonb;
      END IF;
      RETURN value;
    END $$;
    """)

    execute("UPDATE oban_jobs SET args = pg_temp.rename_runtime_references(args)")

    execute("""
    UPDATE ai_gateway_messages SET metadata = jsonb_set(metadata,
      '{request_metadata}', pg_temp.rename_runtime_references(metadata->'request_metadata'))
    WHERE metadata ? 'request_metadata'
    """)

    execute("""
    DO $$
    DECLARE col record;
    BEGIN
      FOR col IN SELECT table_name, column_name FROM information_schema.columns
        WHERE table_schema = 'public' AND data_type = 'jsonb'
          AND column_name IN ('created_by', 'source_provenance', 'reply_route', 'runtime_projection', 'request_context')
      LOOP
        EXECUTE format('UPDATE %I SET %I = pg_temp.rename_runtime_references(%I) WHERE %I IS NOT NULL',
          col.table_name, col.column_name, col.column_name, col.column_name);
      END LOOP;
    END $$
    """)
  end

  def down do
    raise Ecto.MigrationError,
      message: "restore the pre-upgrade database backup and its matching runtime code"
  end
end
