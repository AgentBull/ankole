defmodule Ankole.Repo.Migrations.CreatePodSpreadsheets do
  use Ecto.Migration

  # The operation log and the rebuildable search cache of spreadsheet file
  # pages, and spreadsheet versions in the page history. The workbook bytes stay
  # in the page's Drive object. Both new tables reference the page's Pod
  # properties row, which holds the revision that keys every log entry. An
  # operation stores the operation as the kernel committed it, which can differ
  # from the request after a rebase, so `request_sha256` keeps the digest of the
  # request for idempotent retries. A spreadsheet snapshot names a file object
  # instead of carrying document XML.
  def up do
    execute """
    CREATE TABLE pod_spreadsheet_ops (
      tenant_id      uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      page_id        uuid NOT NULL,
      revision       bigint NOT NULL,
      kind           text NOT NULL CHECK (kind IN ('op', 'reset')),
      compacted      boolean NOT NULL DEFAULT false,
      client_id      text,
      client_seq     bigint,
      request_sha256 bytea,
      op             jsonb,
      author         text NOT NULL,
      created_at     timestamptz NOT NULL,
      PRIMARY KEY (tenant_id, page_id, revision),
      CONSTRAINT pod_spreadsheet_ops_client_seq_key UNIQUE (tenant_id, page_id, client_id, client_seq),
      CONSTRAINT pod_spreadsheet_ops_entry_shape CHECK (
        (kind = 'op' AND client_id IS NOT NULL AND client_seq IS NOT NULL
          AND request_sha256 IS NOT NULL AND octet_length(request_sha256) = 32
          AND op IS NOT NULL AND jsonb_typeof(op) = 'object')
        OR (kind = 'reset' AND client_id IS NULL AND client_seq IS NULL
          AND request_sha256 IS NULL AND op IS NULL)
      ),
      FOREIGN KEY (tenant_id, page_id) REFERENCES pages (tenant_id, id) ON DELETE CASCADE
    )
    """

    execute """
    CREATE INDEX pod_spreadsheet_ops_uncompacted_index
      ON pod_spreadsheet_ops (tenant_id, page_id, revision) WHERE NOT compacted
    """

    execute """
    CREATE TABLE pod_file_caches (
      tenant_id  uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      page_id    uuid NOT NULL,
      subtype    text NOT NULL CHECK (subtype IN ('spreadsheet')),
      object_id  uuid NOT NULL,
      plain_text text NOT NULL DEFAULT '',
      metadata   jsonb NOT NULL DEFAULT '{}',
      updated_at timestamptz NOT NULL,
      PRIMARY KEY (tenant_id, page_id),
      FOREIGN KEY (tenant_id, page_id) REFERENCES pages (tenant_id, id) ON DELETE CASCADE
    )
    """

    execute "CREATE INDEX pod_file_caches_text_trgm_index ON pod_file_caches USING gin (plain_text gin_trgm_ops)"

    execute "ALTER TABLE page_snapshots ALTER COLUMN content DROP NOT NULL"
    execute "ALTER TABLE page_snapshots ADD COLUMN object_id uuid"

    execute """
    ALTER TABLE page_snapshots
      ADD CONSTRAINT page_snapshots_object_fkey FOREIGN KEY (tenant_id, object_id)
        REFERENCES file_objects (tenant_id, id) ON DELETE RESTRICT,
      ADD CONSTRAINT page_snapshots_content_shape CHECK ((content IS NULL) <> (object_id IS NULL)),
      DROP CONSTRAINT page_snapshots_reason_check,
      ADD CONSTRAINT page_snapshots_reason_check CHECK (reason IN
        ('created', 'baseline', 'checkpoint', 'uploaded', 'before_restore', 'restored'))
    """

    # File collection probes this index for every candidate object.
    execute """
    CREATE INDEX page_snapshots_object_index
      ON page_snapshots (tenant_id, object_id) WHERE object_id IS NOT NULL
    """
  end

  def down do
    execute "DELETE FROM page_snapshots WHERE object_id IS NOT NULL"
    execute "DROP INDEX page_snapshots_object_index"

    execute """
    ALTER TABLE page_snapshots
      DROP CONSTRAINT page_snapshots_reason_check,
      ADD CONSTRAINT page_snapshots_reason_check CHECK (reason IN
        ('created', 'baseline', 'checkpoint', 'before_restore', 'restored')),
      DROP CONSTRAINT page_snapshots_content_shape,
      DROP CONSTRAINT page_snapshots_object_fkey,
      DROP COLUMN object_id,
      ALTER COLUMN content SET NOT NULL
    """

    for table <- ~w(pod_file_caches pod_spreadsheet_ops) do
      execute "DROP TABLE #{table}"
    end
  end
end
