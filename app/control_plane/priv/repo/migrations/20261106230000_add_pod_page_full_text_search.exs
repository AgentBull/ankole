defmodule Ankole.Repo.Migrations.AddPodPageFullTextSearch do
  use Ecto.Migration

  # Adds the unified Pod page search projection (`page_search_documents` with a
  # multi-field `pg_search` BM25 index and title trigram index), per-principal
  # recent search history (`pod_search_queries`), and widened `pod_file_caches`
  # extraction state (`subtype`, `format`, `extractor_version`, `extract_status`,
  # `extract_error`) while moving extracted file plain text into `body_text` on
  # `page_search_documents`.
  def up do
    execute """
    CREATE TABLE page_search_documents (
      page_id    uuid PRIMARY KEY,
      tenant_id  uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      title      text NOT NULL DEFAULT '',
      meta_text  text NOT NULL DEFAULT '',
      body_text  text NOT NULL DEFAULT '',
      updated_at timestamptz NOT NULL,
      CONSTRAINT page_search_documents_tenant_id_page_id_fkey
        FOREIGN KEY (tenant_id, page_id) REFERENCES pages (tenant_id, id) ON DELETE CASCADE
    )
    """

    execute """
    CREATE TABLE pod_search_queries (
      tenant_id     uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      id            uuid NOT NULL,
      principal_uid text NOT NULL,
      query         text NOT NULL,
      result_count  integer NOT NULL DEFAULT 0,
      updated_at    timestamptz NOT NULL,
      PRIMARY KEY (tenant_id, id),
      CONSTRAINT pod_search_queries_result_count_check CHECK (result_count >= 0),
      CONSTRAINT pod_search_queries_principal_query_key
        UNIQUE (tenant_id, principal_uid, query)
    )
    """

    execute """
    CREATE INDEX pod_search_queries_recent_idx
      ON pod_search_queries (tenant_id, principal_uid, updated_at DESC, id DESC)
    """

    execute """
    INSERT INTO page_search_documents (page_id, tenant_id, title, meta_text, body_text, updated_at)
    SELECT
      p.id,
      p.tenant_id,
      translate(
        normalize(
          replace(replace(COALESCE(NULLIF(btrim(p.title), ''), p.name, ''), E'\r\n', E'\n'), E'\r', E'\n'),
          NFKC
        ),
        E'\x1e\x1f',
        ''
      ),
      translate(
        normalize(
          replace(
            replace(
              btrim(concat_ws(E'\n',
                CASE
                  WHEN p.type = 'file' AND p.name IS NOT NULL AND p.name <> COALESCE(btrim(p.title), '')
                    THEN p.name
                  ELSE NULL
                END,
                CASE
                  WHEN p.type = 'knowledge' AND jsonb_typeof(p.metadata) = 'object' THEN (
                    SELECT string_agg(val, E'\n')
                    FROM (
                      SELECT CASE
                        WHEN jsonb_typeof(e.value) = 'string' THEN e.value #>> '{}'
                        WHEN jsonb_typeof(e.value) = 'array' THEN (
                          SELECT string_agg(elem #>> '{}', ' ')
                          FROM jsonb_array_elements(e.value) elem
                          WHERE jsonb_typeof(elem) IN ('string', 'number')
                        )
                        WHEN jsonb_typeof(e.value) = 'number' THEN e.value::text
                        ELSE NULL
                      END AS val
                      FROM jsonb_each(p.metadata - 'subtype' - 'extract_facts') e
                      ORDER BY e.key
                    ) kv
                    WHERE val IS NOT NULL AND btrim(val) <> ''
                  )
                  ELSE NULL
                END,
                CASE
                  WHEN p.type = 'base' THEN (
                    SELECT string_agg(part, E'\n')
                    FROM (
                      SELECT bt.name AS part
                      FROM base_tables bt
                      WHERE bt.tenant_id = p.tenant_id AND bt.page_id = p.id AND bt.deleting_at IS NULL
                      UNION ALL
                      SELECT bv.name AS part
                      FROM base_tables bt
                      JOIN base_views bv ON bv.tenant_id = bt.tenant_id AND bv.table_id = bt.id
                      WHERE bt.tenant_id = p.tenant_id AND bt.page_id = p.id AND bt.deleting_at IS NULL
                      UNION ALL
                      SELECT bf.name AS part
                      FROM base_tables bt
                      JOIN base_fields bf ON bf.tenant_id = bt.tenant_id AND bf.table_id = bt.id
                      WHERE bt.tenant_id = p.tenant_id AND bt.page_id = p.id AND bt.deleting_at IS NULL
                    ) base_meta
                    WHERE part IS NOT NULL AND btrim(part) <> ''
                  )
                  ELSE NULL
                END
              )),
              E'\r\n',
              E'\n'
            ),
            E'\r',
            E'\n'
          ),
          NFKC
        ),
        E'\x1e\x1f',
        ''
      ),
      translate(
        normalize(
          replace(
            replace(
              COALESCE(
                CASE
                  WHEN pc.content IS NOT NULL
                   AND pc.content ~ '<(bookmark|media|embed|img)\\y'
                   AND xml_is_well_formed_document(pc.content)
                  THEN concat_ws(
                    E'\n',
                    NULLIF(pc.plain_text, ''),
                    NULLIF(
                      array_to_string(
                        xpath(
                          '//bookmark/@title | //bookmark/@description | //bookmark/@src | //media/@title | //media/@description | //embed/@title | //embed/@href | //img/@alt | //img/@title',
                          pc.content::xml
                        )::text[],
                        E'\n'
                      ),
                      ''
                    )
                  )
                  ELSE pc.plain_text
                END,
                fc.plain_text,
                ''
              ),
              E'\r\n',
              E'\n'
            ),
            E'\r',
            E'\n'
          ),
          NFKC
        ),
        E'\x1e\x1f',
        ''
      ),
      p.updated_at
    FROM pages p
    LEFT JOIN page_contents pc ON pc.tenant_id = p.tenant_id AND pc.page_id = p.id
    LEFT JOIN pod_file_caches fc ON fc.tenant_id = p.tenant_id AND fc.page_id = p.id
    """

    execute """
    CREATE INDEX page_search_documents_tenant_idx
      ON page_search_documents (tenant_id)
    """

    execute """
    CREATE INDEX page_search_documents_title_trgm_idx
      ON page_search_documents USING gin (title gin_trgm_ops)
    """

    execute """
    CREATE INDEX page_search_documents_bm25_idx
      ON page_search_documents
      USING bm25 (page_id, tenant_id, (title::pdb.icu), (meta_text::pdb.icu), (body_text::pdb.icu))
      WITH (key_field='page_id')
    """

    execute "DROP INDEX pod_file_caches_text_trgm_index"

    execute """
    ALTER TABLE pod_file_caches
      DROP CONSTRAINT pod_file_caches_subtype_check,
      ADD CONSTRAINT pod_file_caches_subtype_check CHECK (subtype IN ('spreadsheet', 'text', 'document')),
      ADD COLUMN format text NOT NULL DEFAULT 'xlsx',
      ADD COLUMN extractor_version integer NOT NULL DEFAULT 1,
      ADD COLUMN extract_status text NOT NULL DEFAULT 'ok',
      ADD CONSTRAINT pod_file_caches_extract_status_check CHECK (extract_status IN ('ok', 'skipped', 'failed')),
      ADD COLUMN extract_error text,
      DROP COLUMN plain_text
    """

    execute """
    CREATE INDEX pod_file_caches_object_format_idx
      ON pod_file_caches (tenant_id, object_id, format)
      WHERE extract_status = 'ok'
    """
  end

  def down do
    execute "DROP INDEX pod_file_caches_object_format_idx"

    execute """
    ALTER TABLE pod_file_caches
      ADD COLUMN plain_text text NOT NULL DEFAULT ''
    """

    execute """
    UPDATE pod_file_caches fc
      SET plain_text = COALESCE(psd.body_text, '')
      FROM page_search_documents psd
      WHERE psd.tenant_id = fc.tenant_id
        AND psd.page_id = fc.page_id
        AND fc.subtype = 'spreadsheet'
    """

    execute """
    DELETE FROM pod_file_caches
      WHERE subtype <> 'spreadsheet' OR extract_status <> 'ok'
    """

    execute """
    ALTER TABLE pod_file_caches
      DROP CONSTRAINT pod_file_caches_extract_status_check,
      DROP COLUMN extract_error,
      DROP COLUMN extract_status,
      DROP COLUMN extractor_version,
      DROP COLUMN format,
      DROP CONSTRAINT pod_file_caches_subtype_check,
      ADD CONSTRAINT pod_file_caches_subtype_check CHECK (subtype IN ('spreadsheet'))
    """

    execute """
    CREATE INDEX pod_file_caches_text_trgm_index
      ON pod_file_caches USING gin (plain_text gin_trgm_ops)
    """

    execute "DROP TABLE pod_search_queries"
    execute "DROP TABLE page_search_documents"
  end
end
