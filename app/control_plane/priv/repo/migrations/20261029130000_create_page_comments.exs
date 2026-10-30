defmodule Ankole.Repo.Migrations.CreatePageComments do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE page_comments (
      id uuid PRIMARY KEY,
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      page_id uuid NOT NULL,
      root_id uuid,
      body text,
      author text NOT NULL,
      updated_by text NOT NULL,
      deleted_by text,
      version bigint NOT NULL DEFAULT 1,
      quote text,
      anchor_revision bigint,
      resolved_at timestamptz,
      resolved_by text,
      deleted_at timestamptz,
      created_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL,
      CONSTRAINT page_comments_page_fkey FOREIGN KEY (tenant_id, page_id) REFERENCES pages(tenant_id, id) ON DELETE CASCADE,
      CONSTRAINT page_comments_scope_key UNIQUE (tenant_id, page_id, id),
      CONSTRAINT page_comments_root_fkey FOREIGN KEY (tenant_id, page_id, root_id) REFERENCES page_comments(tenant_id, page_id, id) ON DELETE CASCADE,
      CONSTRAINT page_comments_body_shape CHECK (
        (deleted_at IS NULL AND deleted_by IS NULL AND body IS NOT NULL AND char_length(body) <= 20000 AND body ~ '[^[:space:]]')
        OR (deleted_at IS NOT NULL AND deleted_by IS NOT NULL AND body IS NULL)
      ),
      CONSTRAINT page_comments_version CHECK (version > 0),
      CONSTRAINT page_comments_root_shape CHECK (root_id IS NULL OR (root_id <> id AND quote IS NULL AND anchor_revision IS NULL AND resolved_at IS NULL)),
      CONSTRAINT page_comments_resolution_shape CHECK ((resolved_at IS NULL) = (resolved_by IS NULL)),
      CONSTRAINT page_comments_anchor_shape CHECK ((quote IS NULL) = (anchor_revision IS NULL) AND (anchor_revision IS NULL OR anchor_revision >= 0))
    )
    """)

    execute(
      "CREATE INDEX page_comments_page_roots ON page_comments(tenant_id, page_id, id DESC) WHERE root_id IS NULL"
    )

    execute(
      "CREATE INDEX page_comments_replies ON page_comments(tenant_id, page_id, root_id, id)"
    )

    execute("""
    CREATE FUNCTION check_page_comment_root() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.root_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM page_comments root
        WHERE root.tenant_id = NEW.tenant_id AND root.page_id = NEW.page_id AND root.id = NEW.root_id AND root.root_id IS NULL
      ) THEN
        RAISE EXCEPTION 'Replies must reference a root comment on the same page' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END $$
    """)

    execute("""
    CREATE TRIGGER page_comments_one_reply_level BEFORE INSERT OR UPDATE OF root_id, page_id, tenant_id ON page_comments
      FOR EACH ROW EXECUTE FUNCTION check_page_comment_root()
    """)

    execute(permission_constraints())
    execute(&backfill_comments!/0)
  end

  def down do
    raise Ecto.MigrationError,
      message: "Document comments and permissions require restoring the database backup."
  end

  defp permission_constraints do
    actions = "'page_view', 'page_write_records', 'page_edit', 'page_manage', 'page_comment'"

    """
    ALTER TABLE permission_grants
      DROP CONSTRAINT permission_grants_owner_shape,
      DROP CONSTRAINT permission_grants_pod_action_shape,
      ADD CONSTRAINT permission_grants_owner_shape CHECK (
        num_nonnulls(principal_uid, group_id, source_page_id) = 1 AND (
          (source_page_id IS NULL AND source_action IS NULL) OR
          (source_page_id IS NOT NULL AND source_action IS NOT NULL AND source_action IN (#{actions}) AND target_page_id IS NOT NULL)
        )
      ),
      ADD CONSTRAINT permission_grants_pod_action_shape CHECK (
        (action NOT IN (#{actions}) AND target_page_id IS NULL AND target_scope IS NULL
          AND resource_pattern <> '**' AND resource_pattern NOT LIKE 'pod:%') OR
        (action IN (#{actions}) AND (
          (target_page_id IS NULL AND target_scope IS NULL AND
            (resource_pattern = 'pod:space:**' OR resource_pattern ~ '^pod:private:[a-z0-9_-]+:\\*\\*$')) OR
          (target_page_id IS NOT NULL AND target_scope IS NOT NULL AND target_scope IN ('container', 'self')
            AND resource_pattern = ('pod:**' || ':' || target_page_id::text || ':' || CASE target_scope WHEN 'container' THEN '**' ELSE 'page' END)
            AND (source_page_id IS NULL OR source_page_id <> target_page_id))
        ))
      );
    """
  end

  defp backfill_comments! do
    %{rows: rows} =
      repo().query!("""
      SELECT (array_agg(id ORDER BY inserted_at, id))[1]
      FROM permission_grants
      WHERE action IN ('page_view', 'page_write_records', 'page_edit', 'page_manage')
      GROUP BY tenant_id, principal_uid, group_id, source_page_id, source_action,
        resource_pattern, condition, target_page_id, target_scope
      HAVING array_agg(DISTINCT action ORDER BY action) = ARRAY['page_view', 'page_write_records']
        OR array_agg(DISTINCT action ORDER BY action) = ARRAY['page_edit', 'page_view', 'page_write_records']
        OR array_agg(DISTINCT action ORDER BY action) = ARRAY['page_edit', 'page_manage', 'page_view', 'page_write_records']
      """)

    for [id] <- rows do
      repo().query!(
        """
        INSERT INTO permission_grants (
          id, tenant_id, principal_uid, group_id, source_page_id, source_action,
          resource_pattern, action, condition, target_page_id, target_scope, description, metadata, inserted_at, updated_at
        ) SELECT $1, tenant_id, principal_uid, group_id, source_page_id, source_action,
          resource_pattern, 'page_comment', condition, target_page_id, target_scope, description, metadata, inserted_at, updated_at
        FROM permission_grants WHERE id = $2 ON CONFLICT DO NOTHING
        """,
        [Ecto.UUID.dump!(Ankole.Ecto.UUIDv7.autogenerate()), id]
      )
    end
  end
end
