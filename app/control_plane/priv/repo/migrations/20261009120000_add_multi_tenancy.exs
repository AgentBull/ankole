defmodule Ankole.Repo.Migrations.AddMultiTenancy do
  use Ecto.Migration

  # A frozen application-generated UUID keeps migration replay independent of
  # the current kernel and does not add a database identifier generator.
  @default_tenant_id "019a2b00-0000-7000-8000-000000000001"

  @tenant_tables ~w(
    actor_cron_schedules
    actor_events
    actor_scheduled_events
    actor_session_workspaces
    agent_files
    agent_library_container_entries
    agent_plugin_overrides
    agent_skill_lessons
    agent_skills
    agent_workers
    agents
    ai_gateway_artifacts
    ai_gateway_compaction_artifacts
    ai_gateway_conversations
    ai_gateway_messages
    ai_gateway_usage_records
    automation_job_runs
    automation_jobs
    background_agent_job_turn_items
    background_agent_job_turns
    background_agent_jobs
    brain_chunks
    brain_claims
    brain_contradictions
    brain_links
    brain_merge_suggestions
    brain_object_aliases
    brain_object_versions
    brain_objects
    brain_schema_calibration_domains
    brain_schema_link_types
    brain_schema_packs
    brain_schema_suggestions
    brain_schema_types
    brain_slug_aliases
    brain_sources
    brain_tags
    brain_take_domain_assignments
    brain_timelines
    conversation_tool_receipts
    human_access_events
    human_access_restrictions
    human_user_local_credentials
    human_users
    identity_directory_events
    identity_directory_states
    identity_mapping_requests
    oidc_authorization_codes
    oidc_client_groups
    oidc_clients
    oidc_logout_deliveries
    oidc_logout_requests
    oidc_refresh_tokens
    oidc_sessions
    permission_grants
    principal_external_identities
    principal_group_external_bindings
    principal_group_memberships
    principal_groups
    principals
    signal_gateway_ambient_judgments
    signal_gateway_bindings
    signal_gateway_channels
    signal_gateway_entries
    signal_gateway_inbound_batches
    signal_gateway_input_tombstones
    signal_gateway_outbox_entries
    signal_gateway_webhook_endpoints
    workflow_agent_calls
    workflow_runs
  )

  def up do
    reject_reserved_group_collision()

    create table(:tenants, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :slug, :text, null: false
      add :display_name, :text, null: false
      add :suspended_at, :utc_datetime_usec
      add :deleting_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tenants, [:slug])

    create constraint(:tenants, :tenants_slug_format,
             check: "slug ~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'"
           )

    create constraint(:tenants, :tenants_display_name_present, check: "btrim(display_name) <> ''")

    execute("""
    INSERT INTO tenants (id, slug, display_name, inserted_at, updated_at)
    VALUES ('#{@default_tenant_id}', 'default', 'Default', now(), now())
    """)

    for table <- @tenant_tables, sql <- tenant_column_sqls(table), do: execute(sql)

    create unique_index(:principals, [:tenant_id],
             name: :principals_one_system_per_tenant_index,
             where: "type = 'system'"
           )

    add_site_row_ownership()
    drop_natural_foreign_keys()
    replace_natural_keys()
    add_natural_foreign_keys()
    scope_list_indexes()
    migrate_admin_group()
    migrate_agent_handles()
    migrate_actor_references()

    # Work retains the historical authorizer UID after its Human or tenant
    # disappears. WorkAccess checks the live Principal before any execution;
    # the missing subject revokes work without deleting another tenant's facts.
    for table <-
          ~w(actor_cron_schedules actor_events actor_scheduled_events automation_jobs background_agent_jobs workflow_runs) do
      execute("ALTER TABLE #{table} DROP CONSTRAINT #{table}_human_uid_fkey")
    end

    migrate_plaintext_configuration()

    execute("""
    UPDATE oban_jobs
    SET args = args || jsonb_build_object('tenant_id', '#{@default_tenant_id}'::text)
    WHERE state IN ('available', 'scheduled', 'retryable', 'executing')
    """)
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "tenant ownership and actor attribution cannot be removed; restore the pre-upgrade backup"
  end

  defp reject_reserved_group_collision do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM principal_groups WHERE name = 'siteadmin') THEN
        RAISE EXCEPTION 'The group name siteadmin is reserved for site administration. Rename the existing group, then run this migration again.';
      END IF;
    END $$
    """)
  end

  defp add_site_row_ownership do
    for table <- ~w(app_configurations agent_computer_worker_envs),
        sql <- site_row_ownership_sqls(table),
        do: execute(sql)

    alter table(:browser_login_transactions) do
      add :tenant_id, references(:tenants, type: :uuid, on_delete: :restrict)
    end

    execute("UPDATE browser_login_transactions SET tenant_id = '#{@default_tenant_id}'")
    execute("ALTER TABLE browser_login_transactions ALTER COLUMN tenant_id SET NOT NULL")
    create index(:browser_login_transactions, [:tenant_id])
  end

  defp natural_foreign_keys do
    [
      {"signal_gateway_entries", "signal_channel_id", "signal_gateway_channels", "id", "CASCADE",
       "NO ACTION"},
      {"signal_gateway_inbound_batches", "signal_channel_id", "signal_gateway_channels", "id",
       "CASCADE", "NO ACTION"},
      {"signal_gateway_input_tombstones", "signal_channel_id", "signal_gateway_channels", "id",
       "CASCADE", "NO ACTION"},
      {"brain_claims", "signal_gateway_channel_id", "signal_gateway_channels", "id", "RESTRICT",
       "NO ACTION"},
      {"brain_claims", "object_slug", "brain_objects", "slug", "CASCADE", "CASCADE"},
      {"brain_timelines", "object_slug", "brain_objects", "slug", "CASCADE", "CASCADE"},
      {"brain_timelines", "event_object_slug", "brain_objects", "slug",
       "SET NULL (event_object_slug)", "CASCADE"},
      {"brain_links", "from_object_slug", "brain_objects", "slug", "CASCADE", "CASCADE"},
      {"brain_links", "to_object_slug", "brain_objects", "slug", "CASCADE", "CASCADE"},
      {"brain_links", "origin_object_slug", "brain_objects", "slug",
       "SET NULL (origin_object_slug)", "CASCADE"},
      {"brain_tags", "object_slug", "brain_objects", "slug", "CASCADE", "CASCADE"},
      {"brain_slug_aliases", "canonical_slug", "brain_objects", "slug", "CASCADE", "CASCADE"},
      {"brain_object_aliases", "object_slug", "brain_objects", "slug", "CASCADE", "CASCADE"},
      {"brain_schema_types", "pack_name", "brain_schema_packs", "name", "RESTRICT", "NO ACTION"},
      {"brain_schema_link_types", "pack_name", "brain_schema_packs", "name", "RESTRICT",
       "NO ACTION"},
      {"brain_schema_calibration_domains", "pack_name", "brain_schema_packs", "name", "RESTRICT",
       "NO ACTION"}
    ]
  end

  defp drop_natural_foreign_keys do
    for {table, column, _, _, _, _} <- natural_foreign_keys() do
      execute("ALTER TABLE #{table} DROP CONSTRAINT #{table}_#{column}_fkey")
    end
  end

  defp add_natural_foreign_keys do
    for {table, column, parent, parent_column, on_delete, on_update} <- natural_foreign_keys() do
      execute(
        "ALTER TABLE #{table} ADD CONSTRAINT #{table}_#{column}_fkey " <>
          "FOREIGN KEY (tenant_id, #{column}) REFERENCES #{parent} (tenant_id, #{parent_column}) " <>
          "ON DELETE #{on_delete} ON UPDATE #{on_update}"
      )
    end
  end

  defp replace_natural_keys do
    for {table, columns} <- [
          {"signal_gateway_channels", "tenant_id, id"},
          {"signal_gateway_entries", "tenant_id, document_id"},
          {"principal_group_external_bindings", "tenant_id, provider, external_kind, external_id"}
        ] do
      execute("ALTER TABLE #{table} DROP CONSTRAINT #{table}_pkey")
      execute("ALTER TABLE #{table} ADD CONSTRAINT #{table}_pkey PRIMARY KEY (#{columns})")
    end

    for {name, table, columns, suffix} <- [
          {"human_users_email_index", "human_users", "email", " WHERE email IS NOT NULL"},
          {"human_users_mobile_index", "human_users", "mobile", " WHERE mobile IS NOT NULL"},
          {"principal_external_identities_provider_identity_index",
           "principal_external_identities", "provider, external_id", ""},
          {"identity_mapping_requests_subject_index", "identity_mapping_requests",
           "provider, external_id", ""},
          {"principal_groups_name_index", "principal_groups", "name", ""},
          {"identity_directory_states_provider_id_index", "identity_directory_states",
           "provider_id", ""},
          {"identity_directory_events_provider_id_event_id_index", "identity_directory_events",
           "provider_id, event_id", ""},
          {"signal_gateway_entries_source_identity_index", "signal_gateway_entries",
           "signal_channel_id, source_entry_id", ""},
          {"brain_objects_slug_key", "brain_objects", "slug", ""},
          {"brain_schema_packs_name_key", "brain_schema_packs", "name", ""},
          {"brain_schema_types_name_key", "brain_schema_types", "name", ""},
          {"brain_schema_types_prefix_key", "brain_schema_types", "slug_prefix", ""},
          {"brain_schema_link_types_name_key", "brain_schema_link_types", "name", ""},
          {"brain_schema_calibration_domains_name_key", "brain_schema_calibration_domains",
           "name", ""},
          {"brain_sources_kind_upstream_key", "brain_sources", "kind, upstream_id", ""},
          {"brain_chunks_object_position_key", "brain_chunks", "object_id, chunk_index", ""},
          {"brain_claims_extraction_terminal_key", "brain_claims",
           "signal_gateway_channel_id, provenance_session",
           " WHERE provenance LIKE 'ankole-brain-internal:%' AND provenance_session IS NOT NULL"},
          {"brain_timelines_dedup_key", "brain_timelines",
           "object_slug, date, summary, provenance", ""},
          {"brain_timelines_event_dedup_key", "brain_timelines", "event_object_slug, date",
           " WHERE event_object_slug IS NOT NULL"},
          {"brain_links_dedup_key", "brain_links",
           "from_object_slug, to_object_slug, link_type, link_source, origin_object_slug",
           " NULLS NOT DISTINCT"},
          {"brain_tags_object_tag_key", "brain_tags", "object_slug, tag", ""},
          {"brain_slug_aliases_alias_key", "brain_slug_aliases", "alias_slug", ""},
          {"brain_object_aliases_dedup_key", "brain_object_aliases", "alias_norm, object_slug",
           ""},
          {"brain_take_domain_assignments_key", "brain_take_domain_assignments",
           "take_claim_id, domain", ""},
          {"brain_contradictions_pair_key", "brain_contradictions", "a_claim_id, b_claim_id", ""},
          {"brain_schema_suggestions_pending_key", "brain_schema_suggestions", "term, kind",
           " WHERE status = 'pending'"},
          {"brain_merge_suggestions_pair_key", "brain_merge_suggestions", "a_slug, b_slug", ""}
        ] do
      execute("DROP INDEX #{name}")
      execute("CREATE UNIQUE INDEX #{name} ON #{table} (tenant_id, #{columns})#{suffix}")
    end
  end

  defp scope_list_indexes do
    # Preserve partial predicates, expression columns, and sort order while
    # making tenant list queries use each existing B-tree index.
    tables = Enum.map_join(@tenant_tables, ",", &"'#{&1}'")

    execute("""
    DO $$ DECLARE item record; definition text; BEGIN
      FOR item IN
        SELECT index_row.indexrelid, index_class.relname AS name
        FROM pg_index index_row
        JOIN pg_class table_class ON table_class.oid = index_row.indrelid
        JOIN pg_class index_class ON index_class.oid = index_row.indexrelid
        JOIN pg_am access_method ON access_method.oid = index_class.relam
        JOIN pg_namespace namespace ON namespace.oid = table_class.relnamespace
        WHERE namespace.nspname = current_schema()
          AND table_class.relname IN (#{tables})
          AND access_method.amname = 'btree'
          AND NOT index_row.indisunique
          AND NOT EXISTS (
            SELECT 1 FROM pg_attribute column_row
            WHERE column_row.attrelid = table_class.oid
              AND column_row.attname = 'tenant_id'
              AND column_row.attnum = ANY(index_row.indkey)
          )
      LOOP
        definition := replace(pg_get_indexdef(item.indexrelid), ' USING btree (', ' USING btree (tenant_id, ');
        EXECUTE format('DROP INDEX %I', item.name);
        EXECUTE definition;
      END LOOP;
    END $$
    """)
  end

  defp migrate_admin_group do
    execute(
      "UPDATE principal_groups SET name = 'siteadmin' WHERE name = 'admin' AND built_in = true"
    )

    execute("""
    UPDATE permission_grants
    SET resource_pattern = 'principal_group:siteadmin' || substring(resource_pattern FROM length('principal_group:admin') + 1)
    WHERE resource_pattern = 'principal_group:admin'
       OR resource_pattern LIKE 'principal_group:admin:%'
    """)

    Enum.each(admin_audience_sqls(), &execute/1)

    execute("""
    INSERT INTO app_configurations (scope, key, value, inserted_at, updated_at)
    VALUES ('global', 'tenants.privileged_slug', '{"type":"plaintext","value":"default"}'::jsonb, now(), now())
    ON CONFLICT (scope, key) DO UPDATE SET value = EXCLUDED.value, updated_at = EXCLUDED.updated_at
    """)
  end

  @doc false
  def site_row_ownership_sqls(table) do
    [
      "ALTER TABLE #{table} ADD COLUMN tenant_id uuid REFERENCES tenants(id) ON DELETE RESTRICT",
      "UPDATE #{table} SET tenant_id = '#{@default_tenant_id}' WHERE scope <> 'global'",
      "ALTER TABLE #{table} DROP CONSTRAINT #{table}_scope_check",
      "ALTER TABLE #{table} ADD CONSTRAINT #{table}_scope_check " <>
        "CHECK (scope = 'global' OR scope ~ '^agent:.+$' OR scope ~ '^tenant:[0-9a-f-]{36}$')",
      "ALTER TABLE #{table} ADD CONSTRAINT #{table}_tenant_scope_check " <>
        "CHECK ((scope = 'global') = (tenant_id IS NULL))",
      "CREATE INDEX #{table}_tenant_id_index ON #{table} (tenant_id)"
    ]
  end

  @doc false
  def tenant_column_sqls(table) do
    [
      "ALTER TABLE #{table} ADD COLUMN tenant_id uuid NOT NULL DEFAULT '#{@default_tenant_id}' REFERENCES tenants(id) ON DELETE RESTRICT",
      "ALTER TABLE #{table} ALTER COLUMN tenant_id DROP DEFAULT",
      "CREATE INDEX #{table}_tenant_id_index ON #{table} (tenant_id)"
    ]
  end

  @doc false
  def admin_audience_sqls do
    for {table, column} <- [
          {"brain_sources", "default_audience_scope"},
          {"brain_chunks", "audience_scope"},
          {"brain_claims", "audience_scope"},
          {"brain_timelines", "audience_scope"}
        ] do
      "UPDATE #{table} SET #{column} = 'group:siteadmin' WHERE #{column} = 'group:admin'"
    end ++
      for table <- ~w(brain_objects brain_object_versions) do
        """
        UPDATE #{table}
        SET body = regexp_replace(body, '([{]%[[:blank:]]*audience[[:blank:]]+scope=")group:admin("[[:blank:]]*%[}])', '\\1group:siteadmin\\2', 'g')
        WHERE body LIKE '%scope="group:admin"%'
        """
      end
  end

  defp migrate_agent_handles do
    alter table(:agents) do
      add :handle, :text
    end

    execute("UPDATE agents SET handle = uid")
    execute("ALTER TABLE agents ALTER COLUMN handle SET NOT NULL")
    create unique_index(:agents, [:tenant_id, :handle])

    create constraint(:agents, :agents_handle_format,
             check: "handle ~ '^[a-z0-9][a-z0-9._-]{0,95}$'"
           )
  end

  defp migrate_actor_references do
    for {table, old_column, new_column} <- [
          {"agents", "created_by_principal_uid", "created_by"},
          {"brain_object_versions", "author_uid", "author"},
          {"brain_claims", "author_uid", "author"},
          {"brain_claims", "resolved_by", "resolved_by"},
          {"signal_gateway_channels", "ambient_standing_orders_set_by",
           "ambient_standing_orders_set_by"},
          {"brain_timelines", "author_uid", "author"},
          {"agent_skill_lessons", "author_uid", "author"},
          {"identity_directory_states", "reviewed_by", "reviewed_by"},
          {"identity_directory_events", "reviewed_by", "reviewed_by"},
          {"brain_schema_suggestions", "decided_by", "decided_by"},
          {"brain_merge_suggestions", "decided_by", "decided_by"},
          {"human_access_events", "actor_uid", "actor"}
        ] do
      execute("ALTER TABLE #{table} DROP CONSTRAINT IF EXISTS #{table}_#{old_column}_fkey")

      execute(
        "UPDATE #{table} SET #{old_column} = 'ankole:#{@default_tenant_id}:principal/' || #{old_column} " <>
          "WHERE #{old_column} IS NOT NULL"
      )

      if old_column != new_column do
        execute("ALTER TABLE #{table} RENAME COLUMN #{old_column} TO #{new_column}")
      end
    end

    execute("""
    UPDATE actor_cron_schedules
    SET created_by = jsonb_set(created_by, '{principal_uid}',
          to_jsonb('ankole:#{@default_tenant_id}:principal/' || (created_by->>'principal_uid')))
    WHERE created_by->>'principal_uid' IS NOT NULL
    """)
  end

  defp migrate_plaintext_configuration do
    execute(plaintext_configuration_sql())
  end

  @doc false
  def plaintext_configuration_sql do
    """
    UPDATE app_configurations
    SET scope = 'tenant:#{@default_tenant_id}', tenant_id = '#{@default_tenant_id}'
    WHERE scope = 'global' AND value->>'type' = 'plaintext'
      AND (key = 'principals.identity_providers.active'
        OR key LIKE 'principals.identity_providers.local.%'
        OR key = 'brain.maintainer_agent_uid')
    """
  end
end
