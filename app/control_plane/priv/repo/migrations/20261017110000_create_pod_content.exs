defmodule Ankole.Repo.Migrations.CreatePodContent do
  use Ecto.Migration

  # Pages, their documents, their change log, per-person page state, and the
  # Database tables. Every table carries `tenant_id`, the application makes each
  # primary key, and every page or table reference uses a composite foreign key
  # on `(tenant_id, id)` so that no row can point at another tenant's row.
  def up do
    execute """
    CREATE TABLE pages (
      id                    uuid PRIMARY KEY,
      tenant_id             uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      parent_id             uuid,
      private_owner_uid     text,
      type                  text NOT NULL CHECK (type IN ('doc', 'database', 'applet', 'file')),
      title                 text NOT NULL DEFAULT '',
      icon                  text,
      position              text COLLATE "C" NOT NULL,
      inherit_permissions   boolean NOT NULL DEFAULT true,
      revision              bigint NOT NULL DEFAULT 0,
      saved_from_message_id uuid,
      created_by            text NOT NULL,
      created_at            timestamptz NOT NULL,
      updated_at            timestamptz NOT NULL,
      deleted_at            timestamptz,
      purge_started_at      timestamptz,
      UNIQUE (tenant_id, id),
      CONSTRAINT pages_purge_state CHECK (purge_started_at IS NULL OR deleted_at IS NOT NULL),
      FOREIGN KEY (tenant_id, parent_id) REFERENCES pages (tenant_id, id) ON DELETE CASCADE,
      CONSTRAINT pages_private_owner CHECK (parent_id IS NULL OR private_owner_uid IS NULL)
    )
    """

    execute "CREATE INDEX pages_parent_position_index ON pages (tenant_id, parent_id, position)"

    execute """
    CREATE TABLE page_contents (
      page_id    uuid PRIMARY KEY,
      tenant_id  uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      content    text NOT NULL,
      plain_text text NOT NULL DEFAULT '',
      updated_by text NOT NULL,
      updated_at timestamptz NOT NULL,
      FOREIGN KEY (tenant_id, page_id) REFERENCES pages (tenant_id, id) ON DELETE CASCADE
    )
    """

    execute """
    CREATE TABLE page_changes (
      tenant_id  uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      page_id    uuid NOT NULL,
      revision   bigint NOT NULL,
      kind       text NOT NULL CHECK (kind IN ('change', 'reset')),
      client_id  text,
      client_seq bigint,
      changes    jsonb,
      author     text NOT NULL,
      created_at timestamptz NOT NULL,
      PRIMARY KEY (tenant_id, page_id, revision),
      UNIQUE (tenant_id, page_id, client_id, client_seq),
      CONSTRAINT page_changes_entry_shape CHECK (
        (kind = 'change' AND client_id IS NOT NULL AND client_seq IS NOT NULL
          AND changes IS NOT NULL AND jsonb_typeof(changes) = 'array')
        OR (kind = 'reset' AND client_id IS NULL AND client_seq IS NULL AND changes IS NULL)
      ),
      FOREIGN KEY (tenant_id, page_id) REFERENCES pages (tenant_id, id) ON DELETE CASCADE
    )
    """

    execute """
    CREATE TABLE page_user_states (
      tenant_id     uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      principal_uid text NOT NULL,
      page_id       uuid NOT NULL,
      favorited_at  timestamptz,
      visited_at    timestamptz,
      PRIMARY KEY (tenant_id, principal_uid, page_id),
      FOREIGN KEY (tenant_id, page_id) REFERENCES pages (tenant_id, id) ON DELETE CASCADE
    )
    """

    execute """
    CREATE INDEX page_user_states_recent_index
      ON page_user_states (tenant_id, principal_uid, visited_at DESC)
    """

    execute """
    CREATE TABLE db_tables (
      id               uuid PRIMARY KEY,
      tenant_id        uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      page_id          uuid NOT NULL,
      name             text NOT NULL,
      position         text COLLATE "C" NOT NULL,
      data_version     bigint NOT NULL DEFAULT 0,
      record_count     integer NOT NULL DEFAULT 0,
      next_auto_number bigint NOT NULL DEFAULT 1,
      UNIQUE (tenant_id, id),
      FOREIGN KEY (tenant_id, page_id) REFERENCES pages (tenant_id, id) ON DELETE CASCADE
    )
    """

    execute """
    CREATE TABLE db_fields (
      id         uuid PRIMARY KEY,
      tenant_id  uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      table_id   uuid NOT NULL,
      name       text NOT NULL,
      position   text COLLATE "C" NOT NULL,
      type       text NOT NULL CHECK (type IN (
                   'text', 'number', 'select', 'datetime', 'checkbox', 'user', 'attachment',
                   'auto_number', 'link', 'formula',
                   'created_at', 'updated_at', 'created_by', 'updated_by')),
      config     jsonb NOT NULL DEFAULT '{}',
      is_primary boolean NOT NULL DEFAULT false,
      version    bigint NOT NULL DEFAULT 1,
      FOREIGN KEY (tenant_id, table_id) REFERENCES db_tables (tenant_id, id) ON DELETE CASCADE
    )
    """

    execute "CREATE UNIQUE INDEX db_fields_one_primary_index ON db_fields (table_id) WHERE is_primary"
    execute "CREATE UNIQUE INDEX db_fields_name_index ON db_fields (table_id, name)"

    execute """
    CREATE TABLE db_views (
      id        uuid PRIMARY KEY,
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      table_id  uuid NOT NULL,
      name      text NOT NULL,
      position  text COLLATE "C" NOT NULL,
      type      text NOT NULL CHECK (type IN ('grid', 'kanban', 'gallery')),
      config    jsonb NOT NULL DEFAULT '{}',
      version   bigint NOT NULL DEFAULT 1,
      FOREIGN KEY (tenant_id, table_id) REFERENCES db_tables (tenant_id, id) ON DELETE CASCADE
    )
    """

    execute """
    CREATE TABLE db_records (
      tenant_id   uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      table_id    uuid NOT NULL,
      id          uuid NOT NULL,
      data        jsonb NOT NULL DEFAULT '{}',
      versions    jsonb NOT NULL DEFAULT '{}',
      external_id text,
      created_by  text NOT NULL,
      created_at  timestamptz NOT NULL,
      updated_by  text NOT NULL,
      updated_at  timestamptz NOT NULL,
      PRIMARY KEY (tenant_id, table_id, id),
      FOREIGN KEY (tenant_id, table_id) REFERENCES db_tables (tenant_id, id) ON DELETE CASCADE
    )
    """

    execute "CREATE INDEX db_records_data_index ON db_records USING gin (data jsonb_path_ops)"

    execute """
    CREATE UNIQUE INDEX db_records_external_index
      ON db_records (tenant_id, table_id, external_id) WHERE external_id IS NOT NULL
    """

    execute """
    CREATE TABLE db_sync_bindings (
      id                uuid PRIMARY KEY,
      tenant_id         uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      table_id          uuid NOT NULL UNIQUE,
      connector         text NOT NULL,
      source            jsonb NOT NULL,
      field_map         jsonb NOT NULL,
      cursor            jsonb,
      automation_job_id bigint,
      status            text NOT NULL CHECK (status IN ('active', 'paused')),
      created_by        text NOT NULL,
      created_at        timestamptz NOT NULL,
      FOREIGN KEY (tenant_id, table_id) REFERENCES db_tables (tenant_id, id) ON DELETE CASCADE
    )
    """
  end

  def down do
    for table <- ~w(db_sync_bindings db_records db_views db_fields db_tables page_user_states
                    page_changes page_contents pages) do
      execute "DROP TABLE #{table}"
    end
  end
end
