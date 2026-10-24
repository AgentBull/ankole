defmodule Ankole.Repo.Migrations.UnifyPodAuthorization do
  use Ecto.Migration

  @legacy_console_namespaces ~w(
    agent_library agent_workers agents ai_gateway_conversations ai_gateway_provider
    ai_gateway_provider_kinds ai_gateway_providers app_configuration app_configurations
    automation_jobs background_agent_jobs brain console_readiness control_plane_plugins
    conversations identity_mapping_requests identity_provider identity_provider_adapters
    identity_providers oidc_client oidc_clients permission_grant permission_grants principal
    principal_group principal_groups principals schedules signal_bindings signals_adapters
    webhooks worker_env worker_envs worker_provider worker_providers
  )
  @legacy_agent_console_namespaces ~w(
    automation_jobs files library model_profile model_profiles schedules sessions signal_bindings
    token_quota worker_env worker_envs workflow
  )

  def up do
    execute_statements("""
    ALTER TABLE principals
      ADD COLUMN membership text;

    UPDATE principals
      SET membership = 'member'
      WHERE type = 'human';

    ALTER TABLE principals
      ADD CONSTRAINT principals_membership_shape CHECK (
        (type = 'human' AND membership IS NOT NULL AND membership IN ('member', 'guest'))
        OR (type IN ('agent', 'system') AND membership IS NULL)
      );

    UPDATE principal_groups
    SET computed_condition = 'principal.type == "human" && principal.membership == "member" && principal.status == "active"'
    WHERE name = 'all_humans'
      AND built_in = true
      AND kind = 'computed';
    """)

    execute_statements("""
    ALTER TABLE permission_grants
      ADD COLUMN source_page_id uuid,
      ADD COLUMN source_action text,
      ADD COLUMN target_page_id uuid,
      ADD COLUMN target_scope text;
    """)

    execute(&migrate_console_grants!/0)

    execute_statements("""
    WITH parsed_pod_grants AS (
      SELECT
        g.id,
        g.tenant_id,
        m[1]::uuid AS page_id,
        CASE m[2]
          WHEN '**' THEN 'container'
          WHEN 'page' THEN 'self'
        END AS scope
      FROM permission_grants g
      CROSS JOIN LATERAL regexp_match(
        g.resource_pattern,
        '^pod:\\*\\*:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}):(\\*\\*|page)$'
      ) AS m
      WHERE g.action IN ('page_view', 'page_edit', 'page_manage')
    )
    UPDATE permission_grants g
    SET target_page_id = p.id,
        target_scope = parsed.scope
    FROM parsed_pod_grants parsed
    JOIN pages p ON p.tenant_id = parsed.tenant_id AND p.id = parsed.page_id
    WHERE g.id = parsed.id;

    DELETE FROM permission_grants g
    WHERE g.action IN ('page_view', 'page_edit', 'page_manage')
      AND g.target_page_id IS NULL
      AND g.resource_pattern !~ '^(pod:space:\\*\\*|pod:private:[a-z0-9_-]+:\\*\\*)$';

    ALTER TABLE permission_grants
      DROP CONSTRAINT permission_grants_owner_shape,
      ADD CONSTRAINT permission_grants_owner_shape CHECK (
        num_nonnulls(principal_uid, group_id, source_page_id) = 1
        AND (
          (source_page_id IS NULL AND source_action IS NULL)
          OR (
            source_page_id IS NOT NULL
            AND source_action IS NOT NULL
            AND source_action IN ('page_view', 'page_edit', 'page_manage')
            AND target_page_id IS NOT NULL
          )
        )
      ),
      ADD CONSTRAINT permission_grants_pod_action_shape CHECK (
        (
          action NOT IN ('page_view', 'page_edit', 'page_manage')
          AND target_page_id IS NULL
          AND target_scope IS NULL
          AND resource_pattern <> '**'
          AND resource_pattern NOT LIKE 'pod:%'
        )
        OR (
          action IN ('page_view', 'page_edit', 'page_manage')
          AND (
            (
              target_page_id IS NULL
              AND target_scope IS NULL
              AND (
                resource_pattern = 'pod:space:**'
                OR resource_pattern ~ '^pod:private:[a-z0-9_-]+:\\*\\*$'
              )
            )
            OR (
              target_page_id IS NOT NULL
              AND target_scope IS NOT NULL
              AND target_scope IN ('container', 'self')
              AND resource_pattern = (
                'pod:**' || ':' || target_page_id::text || ':' ||
                CASE target_scope WHEN 'container' THEN '**' ELSE 'page' END
              )
              AND (source_page_id IS NULL OR source_page_id <> target_page_id)
            )
          )
        )
      ),
      ADD CONSTRAINT permission_grants_source_page_fkey
        FOREIGN KEY (tenant_id, source_page_id)
        REFERENCES pages (tenant_id, id) ON DELETE CASCADE,
      ADD CONSTRAINT permission_grants_target_page_fkey
        FOREIGN KEY (tenant_id, target_page_id)
        REFERENCES pages (tenant_id, id) ON DELETE CASCADE;

    CREATE UNIQUE INDEX permission_grants_userset_natural_index
      ON permission_grants (tenant_id, source_page_id, source_action, resource_pattern, action, condition)
      WHERE source_page_id IS NOT NULL;

    CREATE INDEX permission_grants_pod_target_index
      ON permission_grants (tenant_id, target_page_id, target_scope, action)
      WHERE target_page_id IS NOT NULL;

    CREATE INDEX permission_grants_pod_userset_edge_index
      ON permission_grants (tenant_id, source_page_id, source_action)
      INCLUDE (target_page_id, target_scope, action, condition)
      WHERE source_page_id IS NOT NULL;
    """)

    execute_statements("""
    CREATE EXTENSION IF NOT EXISTS pg_trgm;

    ALTER TABLE pages
      ADD COLUMN has_local_acl boolean NOT NULL DEFAULT false,
      ADD COLUMN is_acl_anchor boolean GENERATED ALWAYS AS (
        parent_id IS NULL
        OR NOT inherit_permissions
        OR has_local_acl
        OR deleted_at IS NOT NULL
      ) STORED,
      ADD COLUMN acl_anchor_id uuid,
      ADD COLUMN parent_anchor_id uuid;

    UPDATE pages p
    SET has_local_acl = EXISTS (
      SELECT 1
      FROM permission_grants g
      WHERE g.tenant_id = p.tenant_id
        AND g.target_page_id = p.id
    );

    WITH RECURSIVE computed AS (
      SELECT
        p.tenant_id,
        p.id,
        p.id AS acl_anchor_id,
        NULL::uuid AS parent_anchor_id
      FROM pages p
      WHERE p.parent_id IS NULL
      UNION ALL
      SELECT
        c.tenant_id,
        c.id,
        CASE WHEN c.is_acl_anchor THEN c.id ELSE parent.acl_anchor_id END AS acl_anchor_id,
        CASE WHEN c.is_acl_anchor THEN parent.acl_anchor_id ELSE NULL END AS parent_anchor_id
      FROM pages c
      JOIN computed parent
        ON c.tenant_id = parent.tenant_id AND c.parent_id = parent.id
    )
    UPDATE pages p
    SET acl_anchor_id = c.acl_anchor_id,
        parent_anchor_id = c.parent_anchor_id
    FROM computed c
    WHERE p.tenant_id = c.tenant_id AND p.id = c.id;

    ALTER TABLE pages
      ALTER COLUMN acl_anchor_id SET NOT NULL,
      ADD CONSTRAINT pages_acl_anchor_shape CHECK (
        (
          is_acl_anchor = true
          AND acl_anchor_id = id
          AND (
            (parent_id IS NULL AND parent_anchor_id IS NULL)
            OR (parent_id IS NOT NULL AND parent_anchor_id IS NOT NULL AND parent_anchor_id <> id)
          )
        )
        OR (
          is_acl_anchor = false
          AND parent_id IS NOT NULL
          AND acl_anchor_id <> id
          AND parent_anchor_id IS NULL
        )
      ),
      ADD CONSTRAINT pages_tenant_acl_anchor_fkey
        FOREIGN KEY (tenant_id, acl_anchor_id)
        REFERENCES pages (tenant_id, id) DEFERRABLE INITIALLY IMMEDIATE,
      ADD CONSTRAINT pages_tenant_parent_anchor_fkey
        FOREIGN KEY (tenant_id, parent_anchor_id)
        REFERENCES pages (tenant_id, id) DEFERRABLE INITIALLY IMMEDIATE;

    DROP INDEX IF EXISTS pages_parent_position_index;
    CREATE INDEX pages_tenant_parent_tree_index
      ON pages (tenant_id, parent_id)
      INCLUDE (id, is_acl_anchor);

    CREATE INDEX pages_parent_position_covering_index
      ON pages (tenant_id, parent_id, position, id)
      INCLUDE (title, icon, type, acl_anchor_id, inherit_permissions, private_owner_uid)
      WHERE deleted_at IS NULL;

    CREATE INDEX pages_acl_anchors_covering_index
      ON pages (tenant_id, id)
      INCLUDE (parent_anchor_id, private_owner_uid, inherit_permissions, deleted_at)
      WHERE is_acl_anchor = true;

    CREATE INDEX pages_tenant_acl_anchor_index
      ON pages (tenant_id, acl_anchor_id, updated_at DESC, id);

    CREATE INDEX pages_tenant_parent_anchor_index
      ON pages (tenant_id, parent_anchor_id)
      WHERE parent_anchor_id IS NOT NULL;

    CREATE INDEX pages_title_trgm_gin_index
      ON pages USING gin (title gin_trgm_ops)
      WHERE deleted_at IS NULL;
    """)
  end

  def down do
    raise Ecto.MigrationError,
      message: "Pod authorization has no automatic rollback. Restore the database backup."
  end

  defp execute_statements(sql) do
    for statement <- String.split(sql, ";", trim: true), do: execute(statement)
  end

  defp migrate_console_grants! do
    %{rows: rows} =
      repo().query!("""
      SELECT id, resource_pattern, action, condition
      FROM permission_grants
      WHERE action NOT IN ('page_view', 'page_edit', 'page_manage')
      ORDER BY id
      """)

    rewrites =
      for [id, pattern, action, condition] <- rows,
          targets = console_patterns(pattern, action),
          targets != [pattern],
          do: {id, pattern, condition, targets}

    conflicts =
      Enum.filter(rewrites, fn {_id, _pattern, condition, _targets} ->
        if condition == "true" do
          false
        else
          case Ankole.Kernel.authz_condition_free_variables(condition) do
            variables when is_list(variables) -> "resource" in variables
            error -> raise "Cannot parse legacy grant condition: #{inspect(error)}"
          end
        end
      end)

    if conflicts != [] do
      grants =
        Enum.map(conflicts, fn {id, pattern, condition, _} ->
          {Ecto.UUID.load!(id), pattern, condition}
        end)

      raise "Console grant conditions reference resource. Review these grants before migration: #{inspect(grants)}"
    end

    for {id, _pattern, _condition, targets} <- rewrites do
      for pattern <- targets do
        repo().query!(
          """
          INSERT INTO permission_grants
            (id, tenant_id, principal_uid, group_id, resource_pattern, action, condition,
             description, metadata, inserted_at, updated_at)
          SELECT $1, tenant_id, principal_uid, group_id, $2, action, condition,
                 description, metadata, inserted_at, updated_at
          FROM permission_grants WHERE id = $3
          ON CONFLICT DO NOTHING
          """,
          [Ecto.UUID.dump!(Ankole.Ecto.UUIDv7.autogenerate()), pattern, id]
        )
      end

      repo().query!("DELETE FROM permission_grants WHERE id = $1", [id])
    end
  end

  defp console_patterns("**", _action), do: ["site_console:**", "tenant_console:**"]
  defp console_patterns("*", _action), do: ["site_console:*", "tenant_console:*"]
  defp console_patterns("pod:space", "update"), do: ["tenant_console:pod_space"]
  defp console_patterns("site_console:" <> _ = pattern, _action), do: [pattern]

  defp console_patterns("tenant_console:" <> suffix = pattern, _action)
       when suffix in ["**", "*", "pod_space"], do: [pattern]

  defp console_patterns("tenant_console:" <> suffix, _action), do: ["site_console:" <> suffix]
  defp console_patterns("site:" <> suffix, _action), do: ["site_console:" <> suffix]

  defp console_patterns(pattern, action)
       when action in ~w(read update delete reset decrypt sync) do
    case String.split(pattern, ":") do
      [namespace | _] when namespace in @legacy_console_namespaces ->
        ["site_console:" <> pattern]

      ["agent", _uid] when action in ~w(read update delete) ->
        ["site_console:" <> pattern]

      ["agent", _uid, namespace | _] when namespace in @legacy_agent_console_namespaces ->
        ["site_console:" <> pattern]

      _runtime_or_unknown ->
        [pattern]
    end
  end

  defp console_patterns(pattern, _action), do: [pattern]
end
