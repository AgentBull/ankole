defmodule Ankole.Repo.Migrations.ServiceAccountsAndLifecycleHardening do
  use Ecto.Migration

  def up do
    # 1. Unified Service Accounts (`F-91`, `F-10`, `F-27b`, `F-08`)
    execute("""
    CREATE TABLE service_accounts (
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      uid text NOT NULL,
      kind text NOT NULL,
      applet_page_id uuid,
      options jsonb DEFAULT '{}'::jsonb NOT NULL,
      inserted_at timestamp without time zone NOT NULL,
      updated_at timestamp without time zone NOT NULL,
      CONSTRAINT service_accounts_pkey PRIMARY KEY (tenant_id, uid),
      CONSTRAINT service_accounts_kind_check
        CHECK (kind = ANY (ARRAY['brain'::text, 'applet'::text, 'external_bot'::text, 'platform'::text])),
      CONSTRAINT service_accounts_options_object
        CHECK (jsonb_typeof(options) = 'object'::text),
      CONSTRAINT service_accounts_applet_page_shape
        CHECK (applet_page_id IS NULL OR kind = 'applet'::text),
      CONSTRAINT service_accounts_principal_fkey
        FOREIGN KEY (tenant_id, uid)
        REFERENCES principals(tenant_id, uid) ON UPDATE CASCADE ON DELETE CASCADE,
      CONSTRAINT service_accounts_applet_page_fkey
        FOREIGN KEY (tenant_id, applet_page_id)
        REFERENCES pages(tenant_id, id) ON DELETE CASCADE
    )
    """)

    execute(
      "COMMENT ON TABLE service_accounts IS 'Tenant service Principals owning Brain, Applet, and external Bot budgets and metadata.'"
    )

    execute("""
    CREATE UNIQUE INDEX service_accounts_applet_page_uidx
      ON service_accounts (tenant_id, applet_page_id)
      WHERE applet_page_id IS NOT NULL
    """)

    # Seed singleton service accounts ("system", "ankole_brain", "ankole_applets") and backfill existing Applets.
    execute("""
    INSERT INTO principals (tenant_id, uid, type, status, display_name, access_version, inserted_at, updated_at)
    SELECT t.id, s.uid, 'system'::public.principal_type, 'active'::public.principal_status, s.display_name, 1, now() AT TIME ZONE 'UTC', now() AT TIME ZONE 'UTC'
    FROM tenants AS t
    CROSS JOIN (
      VALUES
        ('system', 'System'),
        ('ankole_brain', 'Ankole Brain'),
        ('ankole_applets', 'Ankole Applets')
    ) AS s(uid, display_name)
    WHERE t.deleting_at IS NULL
    ON CONFLICT (tenant_id, uid) DO NOTHING
    """)

    execute("""
    INSERT INTO service_accounts (tenant_id, uid, kind, options, inserted_at, updated_at)
    SELECT p.tenant_id, p.uid,
      CASE p.uid
        WHEN 'ankole_brain' THEN 'brain'
        WHEN 'ankole_applets' THEN 'applet'
        ELSE 'platform'
      END,
      '{}'::jsonb,
      now() AT TIME ZONE 'UTC',
      now() AT TIME ZONE 'UTC'
    FROM principals AS p
    WHERE p.type = 'system'::public.principal_type
      AND p.uid IN ('system', 'ankole_brain', 'ankole_applets')
    ON CONFLICT (tenant_id, uid) DO NOTHING
    """)

    execute("""
    INSERT INTO principals (tenant_id, uid, type, status, display_name, access_version, inserted_at, updated_at)
    SELECT
      p.tenant_id,
      'svc_applet_' || replace(p.id::text, '-', ''),
      'system'::public.principal_type,
      'active'::public.principal_status,
      COALESCE(NULLIF(btrim(p.title), ''), NULLIF(btrim(p.name), ''), 'Applet') || ' (Applet)',
      1,
      now() AT TIME ZONE 'UTC',
      now() AT TIME ZONE 'UTC'
    FROM pages AS p
    JOIN tenants AS t ON t.id = p.tenant_id
    WHERE p.type = 'applet' AND t.deleting_at IS NULL
    ON CONFLICT (tenant_id, uid) DO NOTHING
    """)

    execute("""
    INSERT INTO service_accounts (tenant_id, uid, kind, applet_page_id, options, inserted_at, updated_at)
    SELECT
      p.tenant_id,
      'svc_applet_' || replace(p.id::text, '-', ''),
      'applet',
      p.id,
      '{}'::jsonb,
      now() AT TIME ZONE 'UTC',
      now() AT TIME ZONE 'UTC'
    FROM pages AS p
    JOIN tenants AS t ON t.id = p.tenant_id
    WHERE p.type = 'applet' AND t.deleting_at IS NULL
    ON CONFLICT (tenant_id, uid) DO NOTHING
    """)

    # Ensure every existing Applet Page acts as an ACL anchor for its service account.
    execute("""
    WITH RECURSIVE unanchored_applets AS (
      SELECT p.tenant_id, p.id, p.acl_anchor_id AS old_anchor_id
      FROM pages p
      WHERE p.type = 'applet' AND NOT p.is_acl_anchor
    ),
    affected AS (
      SELECT ua.tenant_id, ua.id, false AS was_anchor, ua.id AS new_anchor_id, ua.old_anchor_id
      FROM unanchored_applets ua
      UNION ALL
      SELECT c.tenant_id, c.id, c.is_acl_anchor AS was_anchor,
             CASE WHEN c.type = 'applet' THEN c.id ELSE af.new_anchor_id END AS new_anchor_id,
             af.new_anchor_id AS old_anchor_id
      FROM affected af
      JOIN pages c ON c.tenant_id = af.tenant_id AND c.parent_id = af.id
      WHERE NOT af.was_anchor
    )
    UPDATE pages target
    SET has_local_acl = CASE WHEN target.type = 'applet' THEN true ELSE target.has_local_acl END,
        acl_anchor_id = CASE WHEN af.was_anchor AND target.type <> 'applet' THEN target.id ELSE af.new_anchor_id END,
        parent_anchor_id = CASE WHEN af.was_anchor OR target.type = 'applet' THEN af.old_anchor_id ELSE NULL END
    FROM affected af
    WHERE target.tenant_id = af.tenant_id AND target.id = af.id
    """)

    # 2. Brain Sources default scope lifecycle (`N-02`) & composite SET NULL column lists (`m1`)
    execute("""
    ALTER TABLE brain_sources
      ADD COLUMN attention_reason text,
      ADD CONSTRAINT brain_sources_attention_reason_present
        CHECK (attention_reason IS NULL OR length(btrim(attention_reason)) > 0),
      DROP CONSTRAINT brain_sources_default_source_node_id_fkey,
      ADD CONSTRAINT brain_sources_default_source_node_id_fkey
        FOREIGN KEY (tenant_id, default_source_node_id)
        REFERENCES pages(tenant_id, id) ON DELETE SET NULL (default_source_node_id)
    """)

    execute("""
    ALTER TABLE connector_auth_waits
      DROP CONSTRAINT connector_auth_waits_auth_config_fkey,
      ADD CONSTRAINT connector_auth_waits_auth_config_fkey
        FOREIGN KEY (tenant_id, auth_config_id)
        REFERENCES connector_auth_configs(tenant_id, id) ON DELETE SET NULL (auth_config_id)
    """)

    execute("""
    CREATE INDEX brain_sources_default_source_node_idx
      ON brain_sources (tenant_id, default_source_node_id)
      WHERE default_source_node_id IS NOT NULL
    """)

    # 3. Bounded infrastructure retry budget on Signals (`F-12`)
    execute("""
    ALTER TABLE signals
      ADD COLUMN infrastructure_attempt_count integer DEFAULT 0 NOT NULL,
      DROP CONSTRAINT signals_capacity_attempt_count_check,
      ADD CONSTRAINT signals_capacity_attempt_count_check
        CHECK (
          provider_capacity_attempt_count >= 0
          AND infrastructure_attempt_count >= 0
          AND (provider_capacity_attempt_count + infrastructure_attempt_count) <= attempt_count
        )
    """)

    # 4. Indexed comment mentions for Activity.attention (`F-108`)
    execute("""
    ALTER TABLE page_comments
      ADD COLUMN mentioned_uids text[] DEFAULT '{}'::text[] NOT NULL
    """)

    execute("""
    UPDATE page_comments AS c
    SET mentioned_uids = COALESCE(
      (
        SELECT array_agg(DISTINCT m.uid ORDER BY m.uid)
        FROM (
          SELECT (regexp_matches(c.body, '<mention[^>]*principal="([^"]+)"', 'g'))[1] AS uid
          UNION ALL
          SELECT (regexp_matches(c.body, '\\(principal:([^)\\s]+)\\)', 'g'))[1] AS uid
        ) AS m
        WHERE m.uid IS NOT NULL AND m.uid <> ''
      ),
      '{}'::text[]
    )
    WHERE c.body LIKE '%<mention%' OR c.body LIKE '%(principal:%'
    """)

    execute(
      "CREATE INDEX page_comments_mentioned_uids_idx ON page_comments USING gin (mentioned_uids)"
    )

    # 5. External Bot policy on Signal Bindings (`F-08`)
    execute("""
    ALTER TABLE signal_bindings
      ADD COLUMN external_bot_policy text DEFAULT 'ignore'::text NOT NULL,
      ADD CONSTRAINT signal_bindings_external_bot_policy_check
        CHECK (external_bot_policy = ANY (ARRAY['ignore'::text, 'record_only'::text, 'allow'::text]))
    """)

    # 6. Connector Trigger verification cadence & failure threshold (`F-54`)
    execute("""
    ALTER TABLE connector_triggers
      ADD COLUMN last_verified_at timestamp with time zone,
      ADD COLUMN consecutive_failures integer DEFAULT 0 NOT NULL,
      ADD CONSTRAINT connector_triggers_consecutive_failures_non_negative
        CHECK (consecutive_failures >= 0)
    """)

    # 7. Worker Provider prepared image digest (`F-150[G1-06]`)
    execute("""
    ALTER TABLE worker_providers
      ADD COLUMN prepared_digest text,
      ADD COLUMN prepared_verified_at timestamp without time zone
    """)

    # 8. Applet Route durable idempotency store (`F-137a`)
    execute("""
    CREATE TABLE pod_applet_idempotency_keys (
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      page_id uuid NOT NULL,
      scope_uid text NOT NULL,
      idempotency_key text NOT NULL,
      request_hash text NOT NULL,
      status_code integer NOT NULL,
      response_body jsonb NOT NULL,
      expires_at timestamp without time zone NOT NULL,
      inserted_at timestamp without time zone NOT NULL,
      CONSTRAINT pod_applet_idempotency_keys_pkey
        PRIMARY KEY (tenant_id, page_id, scope_uid, idempotency_key),
      CONSTRAINT pod_applet_idempotency_keys_key_present
        CHECK (length(btrim(idempotency_key)) > 0 AND length(idempotency_key) <= 255),
      CONSTRAINT pod_applet_idempotency_keys_page_fkey
        FOREIGN KEY (tenant_id, page_id)
        REFERENCES pages(tenant_id, id) ON DELETE CASCADE
    )
    """)

    execute("""
    CREATE INDEX pod_applet_idempotency_keys_expires_idx
      ON pod_applet_idempotency_keys (tenant_id, expires_at)
    """)

    # 9. Connector same-turn write receipts (`F-53b`) & approval Action Card kind (`F-51`)
    execute("""
    CREATE TABLE connector_write_receipts (
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      id uuid NOT NULL,
      authority_scope text NOT NULL,
      toolkit text NOT NULL,
      tool_name text NOT NULL,
      args_sha256 text NOT NULL,
      status text NOT NULL,
      http_status integer,
      external_ref text,
      expires_at timestamp without time zone NOT NULL,
      inserted_at timestamp without time zone NOT NULL,
      updated_at timestamp without time zone NOT NULL,
      CONSTRAINT connector_write_receipts_pkey PRIMARY KEY (tenant_id, id),
      CONSTRAINT connector_write_receipts_status_check
        CHECK (status = ANY (ARRAY['in_flight'::text, 'succeeded'::text, 'outcome_unknown'::text])),
      CONSTRAINT connector_write_receipts_scope_present
        CHECK (length(btrim(authority_scope)) > 0)
    )
    """)

    execute("""
    CREATE UNIQUE INDEX connector_write_receipts_scope_call_uidx
      ON connector_write_receipts (tenant_id, authority_scope, toolkit, tool_name, args_sha256)
    """)

    execute("""
    CREATE INDEX connector_write_receipts_expires_idx
      ON connector_write_receipts (tenant_id, expires_at)
    """)

    execute("""
    ALTER TABLE conversation_action_cards
      DROP CONSTRAINT conversation_action_cards_action_kind_check,
      ADD CONSTRAINT conversation_action_cards_action_kind_check
        CHECK ((action_kind = ANY (ARRAY[
          'brain.object.create'::text,
          'pod.knowledge.save'::text,
          'pod.page.set_sharing'::text,
          'pod.page.delete'::text,
          'pod.page.restore'::text,
          'pod.base.delete_table'::text,
          'conversation.add_participants'::text,
          'library.skill.save'::text,
          'connectors.tool.call'::text
        ])))
    """)

    # 10. Complete object_id reference index coverage for Objects.collect (`F-108`)
    execute("CREATE INDEX skill_files_object_index ON skill_files (tenant_id, object_id)")

    execute(
      "CREATE INDEX drive_vfs_exports_object_index ON drive_vfs_exports (tenant_id, object_id)"
    )

    # 11. Per-service-account attribution on AI usage records (`F-91`)
    execute("ALTER TABLE ai_gateway_usage_records ADD COLUMN service_uid text")

    execute("""
    CREATE INDEX ai_gateway_usage_records_service_uid_idx
      ON ai_gateway_usage_records (tenant_id, service_uid, inserted_at)
      WHERE service_uid IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX ai_gateway_usage_records_service_uid_idx")
    execute("ALTER TABLE ai_gateway_usage_records DROP COLUMN service_uid")

    execute("DROP INDEX drive_vfs_exports_object_index")
    execute("DROP INDEX skill_files_object_index")

    execute("DELETE FROM conversation_action_cards WHERE action_kind = 'connectors.tool.call'")

    execute("""
    ALTER TABLE conversation_action_cards
      DROP CONSTRAINT conversation_action_cards_action_kind_check,
      ADD CONSTRAINT conversation_action_cards_action_kind_check
        CHECK ((action_kind = ANY (ARRAY[
          'brain.object.create'::text,
          'pod.knowledge.save'::text,
          'pod.page.set_sharing'::text,
          'pod.page.delete'::text,
          'pod.page.restore'::text,
          'pod.base.delete_table'::text,
          'conversation.add_participants'::text,
          'library.skill.save'::text
        ])))
    """)

    execute("DROP TABLE connector_write_receipts")
    execute("DROP TABLE pod_applet_idempotency_keys")

    execute("""
    ALTER TABLE worker_providers
      DROP COLUMN prepared_verified_at,
      DROP COLUMN prepared_digest
    """)

    execute("""
    ALTER TABLE connector_triggers
      DROP CONSTRAINT connector_triggers_consecutive_failures_non_negative,
      DROP COLUMN consecutive_failures,
      DROP COLUMN last_verified_at
    """)

    execute("""
    ALTER TABLE signal_bindings
      DROP CONSTRAINT signal_bindings_external_bot_policy_check,
      DROP COLUMN external_bot_policy
    """)

    execute("DROP INDEX page_comments_mentioned_uids_idx")
    execute("ALTER TABLE page_comments DROP COLUMN mentioned_uids")

    execute("""
    UPDATE signals
    SET attempt_count = GREATEST(attempt_count, provider_capacity_attempt_count)
    WHERE infrastructure_attempt_count > 0
    """)

    execute("""
    ALTER TABLE signals
      DROP CONSTRAINT signals_capacity_attempt_count_check,
      DROP COLUMN infrastructure_attempt_count,
      ADD CONSTRAINT signals_capacity_attempt_count_check
        CHECK (provider_capacity_attempt_count >= 0 AND provider_capacity_attempt_count <= attempt_count)
    """)

    execute("DROP INDEX brain_sources_default_source_node_idx")

    execute("""
    ALTER TABLE connector_auth_waits
      DROP CONSTRAINT connector_auth_waits_auth_config_fkey,
      ADD CONSTRAINT connector_auth_waits_auth_config_fkey
        FOREIGN KEY (tenant_id, auth_config_id)
        REFERENCES connector_auth_configs(tenant_id, id) ON DELETE SET NULL
    """)

    execute("""
    ALTER TABLE brain_sources
      DROP CONSTRAINT brain_sources_default_source_node_id_fkey,
      ADD CONSTRAINT brain_sources_default_source_node_id_fkey
        FOREIGN KEY (tenant_id, default_source_node_id)
        REFERENCES pages(tenant_id, id) ON DELETE RESTRICT,
      DROP CONSTRAINT brain_sources_attention_reason_present,
      DROP COLUMN attention_reason
    """)

    execute("DROP TABLE service_accounts")
  end
end
