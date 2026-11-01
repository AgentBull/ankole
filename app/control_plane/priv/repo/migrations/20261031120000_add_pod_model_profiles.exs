defmodule Ankole.Repo.Migrations.AddPodModelProfiles do
  use Ecto.Migration

  def up do
    normalize_system_principals()

    execute("""
    INSERT INTO principals (
      tenant_id, uid, type, status, access_version, display_name, inserted_at, updated_at
    )
    SELECT t.id, 'system', 'system', 'active', 1, 'System', now(), now()
    FROM tenants AS t
    WHERE NOT EXISTS (
      SELECT 1 FROM principals AS p WHERE p.tenant_id = t.id AND p.type = 'system'
    )
    """)

    execute("""
    INSERT INTO site_app_configurations (scope, key, value, inserted_at, updated_at)
    SELECT 'global', 'ai_gateway.model_profiles.rerank', value, inserted_at, updated_at
    FROM site_app_configurations
    WHERE scope = 'global' AND key = 'brain.rerank_model'
      AND jsonb_typeof(value -> 'value') = 'object'
    ON CONFLICT (scope, key) DO NOTHING
    """)

    execute("""
    INSERT INTO app_configurations (tenant_id, scope, key, value, inserted_at, updated_at)
    SELECT tenant_id, scope, 'ai_gateway.model_profiles.rerank', value, inserted_at, updated_at
    FROM app_configurations
    WHERE scope LIKE 'tenant:%' AND key = 'brain.rerank_model'
      AND jsonb_typeof(value -> 'value') = 'object'
    ON CONFLICT (tenant_id, scope, key) DO NOTHING
    """)

    execute("DELETE FROM site_app_configurations WHERE key = 'brain.rerank_model'")
    execute("DELETE FROM app_configurations WHERE key = 'brain.rerank_model'")

    execute("""
    DO $migration$
    DECLARE
      tenant_row RECORD;
      seed_uid TEXT;
      seed_options JSONB;
      maintainer_uid TEXT;
      slot TEXT;
      slot_value JSONB;
    BEGIN
      FOR tenant_row IN SELECT id FROM tenants LOOP
        SELECT value ->> 'value' INTO maintainer_uid
        FROM app_configurations
        WHERE tenant_id = tenant_row.id
          AND scope = 'tenant:' || tenant_row.id::text
          AND key = 'brain.maintainer_agent_uid';

        IF maintainer_uid IS NULL THEN
          SELECT value ->> 'value' INTO maintainer_uid
          FROM site_app_configurations
          WHERE scope = 'global' AND key = 'brain.maintainer_agent_uid';
        END IF;

        SELECT a.uid, a.options INTO seed_uid, seed_options
        FROM agents AS a
        WHERE a.tenant_id = tenant_row.id AND a.uid = maintainer_uid;

        IF seed_uid IS NULL THEN
          SELECT a.uid, a.options INTO seed_uid, seed_options
          FROM agents AS a
          JOIN principals AS p ON p.tenant_id = a.tenant_id AND p.uid = a.uid
          WHERE p.tenant_id = tenant_row.id
            AND p.status = 'active'
            AND jsonb_typeof(a.options #> '{ai_agent,models,primary}') = 'object'
          ORDER BY p.inserted_at ASC, p.uid ASC
          LIMIT 1;
        END IF;

        IF seed_uid IS NOT NULL THEN
          FOREACH slot IN ARRAY ARRAY['primary', 'light', 'heavy', 'web_fetch'] LOOP
            slot_value := seed_options #> ARRAY['ai_agent', 'models', slot];

            IF jsonb_typeof(slot_value) = 'object' THEN
              INSERT INTO app_configurations (
                tenant_id, scope, key, value, inserted_at, updated_at
              ) VALUES (
                tenant_row.id,
                'tenant:' || tenant_row.id::text,
                'ai_gateway.model_profiles.' || slot,
                jsonb_build_object('type', 'plaintext', 'value', slot_value),
                now(),
                now()
              ) ON CONFLICT (tenant_id, scope, key) DO NOTHING;
            END IF;
          END LOOP;
        END IF;

        seed_uid := NULL;
        seed_options := NULL;
        maintainer_uid := NULL;
      END LOOP;
    END
    $migration$
    """)

    execute("DELETE FROM site_app_configurations WHERE key = 'brain.maintainer_agent_uid'")
    execute("DELETE FROM app_configurations WHERE key = 'brain.maintainer_agent_uid'")

    execute("""
    DO $migration$
    DECLARE
      agent_row RECORD;
      inherited_value JSONB;
      agent_value JSONB;
      hosted_value JSONB;
      models JSONB;
      slot TEXT;
    BEGIN
      FOR agent_row IN
        SELECT tenant_id, uid, options FROM agents
      LOOP
        FOREACH slot IN ARRAY ARRAY[
          'primary', 'light', 'heavy', 'coding', 'vision_fallback',
          'web_search', 'web_fetch', 'image_generate'
        ] LOOP
          SELECT value -> 'value' INTO inherited_value
          FROM app_configurations
          WHERE tenant_id = agent_row.tenant_id
            AND scope = 'tenant:' || agent_row.tenant_id::text
            AND key = 'ai_gateway.model_profiles.' || slot;

          IF inherited_value IS NULL THEN
            SELECT value -> 'value' INTO inherited_value
            FROM site_app_configurations
            WHERE scope = 'global' AND key = 'ai_gateway.model_profiles.' || slot;
          END IF;

          agent_value := agent_row.options #> ARRAY['ai_agent', 'models', slot];

          IF jsonb_typeof(inherited_value) = 'object' AND agent_value = inherited_value THEN
            models := COALESCE(agent_row.options #> '{ai_agent,models}', '{}'::jsonb) - slot;
            agent_row.options := jsonb_set(
              agent_row.options, '{ai_agent,models}', models, true
            );
          END IF;

          inherited_value := NULL;
          agent_value := NULL;
        END LOOP;

        hosted_value := agent_row.options #> '{ai_agent,provider_hosted}';

        IF jsonb_typeof(hosted_value) = 'object' THEN
          agent_row.options := jsonb_set(
            agent_row.options,
            '{ai_agent,provider_hosted}',
            (
              SELECT COALESCE(jsonb_object_agg(key, value), '{}'::jsonb)
              FROM jsonb_each(hosted_value)
              WHERE value <> 'true'::jsonb
            ),
            true
          );
        END IF;

        UPDATE agents SET options = agent_row.options
        WHERE tenant_id = agent_row.tenant_id AND uid = agent_row.uid;
      END LOOP;
    END
    $migration$
    """)

    drop(constraint(:ai_gateway_usage_records, :ai_gateway_usage_records_origin_check))

    create(
      constraint(:ai_gateway_usage_records, :ai_gateway_usage_records_origin_check,
        check: "origin IN ('agent', 'codex', 'applet', 'brain', 'oidc_human', 'compaction')"
      )
    )
  end

  def down do
    raise Ecto.MigrationError,
          "Pod model profile migration is irreversible: Agent overrides and Brain settings were consolidated into Pod defaults. Restore a pre-upgrade database backup to run the previous version."
  end

  defp normalize_system_principals do
    # Preserve the identity of the single legacy service, including audit
    # references stored as tenant-qualified text rather than foreign keys.
    for {table, column} <- [
          {"agent_skill_lessons", "author"},
          {"agents", "created_by"},
          {"brain_claims", "author"},
          {"brain_claims", "resolved_by"},
          {"brain_merge_suggestions", "decided_by"},
          {"brain_object_versions", "author"},
          {"brain_schema_suggestions", "decided_by"},
          {"brain_timelines", "author"},
          {"drive_nodes", "created_by"},
          {"human_access_events", "actor"},
          {"identity_directory_events", "reviewed_by"},
          {"identity_directory_states", "reviewed_by"},
          {"page_changes", "author"},
          {"page_comments", "activity_by"},
          {"page_comments", "author"},
          {"page_comments", "deleted_by"},
          {"page_comments", "resolved_by"},
          {"page_comments", "updated_by"},
          {"page_contents", "updated_by"},
          {"page_snapshots", "author"}
        ] do
      execute("""
      UPDATE #{table} AS target
      SET #{column} = 'ankole:' || principal.tenant_id::text || ':principal/system'
      FROM principals AS principal
      WHERE principal.type = 'system' AND principal.uid <> 'system'
        AND target.#{column} = 'ankole:' || principal.tenant_id::text || ':principal/' || principal.uid
      """)
    end

    execute("""
    UPDATE page_contents AS target
    SET contributors = ARRAY(
      SELECT coalesce((
        SELECT 'ankole:' || principal.tenant_id::text || ':principal/system'
        FROM principals AS principal
        WHERE principal.type = 'system' AND principal.uid <> 'system'
          AND contributor.value = 'ankole:' || principal.tenant_id::text || ':principal/' || principal.uid
      ), contributor.value)
      FROM unnest(target.contributors) AS contributor(value)
    )
    WHERE EXISTS (
      SELECT 1 FROM principals AS principal
      WHERE principal.type = 'system' AND principal.uid <> 'system'
        AND ('ankole:' || principal.tenant_id::text || ':principal/' || principal.uid) = ANY(target.contributors)
    )
    """)

    execute("""
    UPDATE cron_schedules AS target
    SET created_by = jsonb_set(target.created_by, '{principal_uid}',
      to_jsonb('ankole:' || principal.tenant_id::text || ':principal/system'), false)
    FROM principals AS principal
    WHERE principal.type = 'system' AND principal.uid <> 'system'
      AND target.created_by->>'principal_uid' = 'ankole:' || principal.tenant_id::text || ':principal/' || principal.uid
    """)

    execute("UPDATE principals SET uid = 'system' WHERE type = 'system' AND uid <> 'system'")
  end
end
