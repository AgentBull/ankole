defmodule Ankole.Repo.Migrations.ExpandPodFourBitPermissions do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE permission_grants
      DROP CONSTRAINT permission_grants_owner_shape,
      DROP CONSTRAINT permission_grants_pod_action_shape,
      ADD CONSTRAINT permission_grants_owner_shape CHECK (
        num_nonnulls(principal_uid, group_id, source_page_id) = 1
        AND (
          (source_page_id IS NULL AND source_action IS NULL)
          OR (
            source_page_id IS NOT NULL
            AND source_action IS NOT NULL
            AND source_action IN ('page_view', 'page_write_records', 'page_edit', 'page_manage')
            AND target_page_id IS NOT NULL
          )
        )
      ),
      ADD CONSTRAINT permission_grants_pod_action_shape CHECK (
        (
          action NOT IN ('page_view', 'page_write_records', 'page_edit', 'page_manage')
          AND target_page_id IS NULL
          AND target_scope IS NULL
          AND resource_pattern <> '**'
          AND resource_pattern NOT LIKE 'pod:%'
        )
        OR (
          action IN ('page_view', 'page_write_records', 'page_edit', 'page_manage')
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
      );
    """)

    execute(&backfill_record_grants!/0)

    execute("""
    CREATE INDEX IF NOT EXISTS page_contents_plain_text_trgm_gin_index
      ON page_contents USING gin (plain_text gin_trgm_ops)
    """)
  end

  def down do
    raise Ecto.MigrationError,
      message: "Pod roles have no automatic rollback. Restore the database backup."
  end

  defp backfill_record_grants! do
    %{rows: rows} = repo().query!("SELECT id FROM permission_grants WHERE action = 'page_edit'")

    for [id] <- rows do
      repo().query!(
        """
        INSERT INTO permission_grants (
          id, tenant_id, principal_uid, group_id, source_page_id, source_action,
          resource_pattern, action, condition, target_page_id, target_scope,
          description, metadata, inserted_at, updated_at
        )
        SELECT $1, tenant_id, principal_uid, group_id, source_page_id, source_action,
          resource_pattern, 'page_write_records', condition, target_page_id, target_scope,
          description, metadata, inserted_at, updated_at
        FROM permission_grants WHERE id = $2
        ON CONFLICT DO NOTHING
        """,
        [Ecto.UUID.dump!(Ankole.Ecto.UUIDv7.autogenerate()), id]
      )
    end
  end
end
