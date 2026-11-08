defmodule Ankole.Repo.Migrations.CreateBrainDataSemantics do
  use Ecto.Migration

  # Brain keeps the executable side of its `datasets/` and `metrics/` objects
  # in these tables. A knowledge save validates the page frontmatter and writes
  # them in the same transaction:
  #
  # - `brain_dataset_bindings`: one row per dataset object, binding it to a Base
  #   table or an external connector table with its grain, keys, and joins.
  # - `brain_metric_revisions`: immutable revisions of one metric object. Only
  #   drift detection changes a row, from `published` to `needs_review`.
  # - `brain_entity_identifiers`: business identifiers of Brain entities, one
  #   owner per namespace and value.
  #
  # Workspaces that installed the general pack before the data pack shipped
  # receive the data pack through one queued installation job per workspace.
  def up do
    execute("""
    CREATE TABLE brain_dataset_bindings (
      tenant_id       uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      id              uuid NOT NULL,
      dataset_page_id uuid NOT NULL,
      source_kind     text NOT NULL,
      base_page_id    uuid,
      base_table_id   uuid,
      connection_slug text,
      source_catalog  text,
      source_schema   text,
      source_table    text,
      grain           text NOT NULL,
      primary_key     jsonb NOT NULL DEFAULT '[]',
      business_key    jsonb NOT NULL DEFAULT '[]',
      entity_key      jsonb,
      joins           jsonb NOT NULL DEFAULT '[]',
      field_types     jsonb NOT NULL DEFAULT '{}',
      created_at      timestamptz NOT NULL,
      updated_at      timestamptz NOT NULL,
      PRIMARY KEY (tenant_id, id),
      CONSTRAINT brain_dataset_bindings_dataset_page_id_fkey FOREIGN KEY (tenant_id, dataset_page_id)
        REFERENCES pages (tenant_id, id) ON DELETE CASCADE,
      CONSTRAINT brain_dataset_bindings_source_kind_values CHECK (source_kind IN ('base', 'connector')),
      CONSTRAINT brain_dataset_bindings_source_shape CHECK (
        (source_kind = 'base' AND base_page_id IS NOT NULL AND base_table_id IS NOT NULL
          AND connection_slug IS NULL AND source_table IS NULL)
        OR (source_kind = 'connector' AND connection_slug IS NOT NULL AND source_table IS NOT NULL
          AND base_page_id IS NULL AND base_table_id IS NULL)
      ),
      CONSTRAINT brain_dataset_bindings_grain_present CHECK (btrim(grain) <> ''),
      CONSTRAINT brain_dataset_bindings_json_shape CHECK (
        jsonb_typeof(primary_key) = 'array' AND jsonb_typeof(business_key) = 'array'
          AND jsonb_typeof(joins) = 'array' AND jsonb_typeof(field_types) = 'object'
          AND (entity_key IS NULL OR jsonb_typeof(entity_key) = 'object')
      )
    )
    """)

    execute("""
    CREATE UNIQUE INDEX brain_dataset_bindings_dataset_key
      ON brain_dataset_bindings (tenant_id, dataset_page_id)
    """)

    execute("""
    CREATE TABLE brain_metric_revisions (
      tenant_id          uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      id                 uuid NOT NULL,
      metric_page_id     uuid NOT NULL,
      revision           integer NOT NULL,
      dataset_binding_id uuid,
      source_kind        text NOT NULL,
      source             jsonb NOT NULL,
      spec               jsonb NOT NULL,
      parameters         jsonb NOT NULL DEFAULT '[]',
      field_types        jsonb NOT NULL DEFAULT '{}',
      source_columns     jsonb NOT NULL DEFAULT '[]',
      grain              text NOT NULL,
      unit               text NOT NULL,
      addible_dimensions jsonb NOT NULL DEFAULT '[]',
      time_field         text,
      numerator          text NOT NULL,
      denominator        text,
      status             text NOT NULL,
      review_reason      jsonb,
      page_revision      bigint NOT NULL,
      approved_by        text NOT NULL,
      created_at         timestamptz NOT NULL,
      PRIMARY KEY (tenant_id, id),
      CONSTRAINT brain_metric_revisions_metric_page_id_fkey FOREIGN KEY (tenant_id, metric_page_id)
        REFERENCES pages (tenant_id, id) ON DELETE CASCADE,
      CONSTRAINT brain_metric_revisions_dataset_binding_id_fkey FOREIGN KEY (tenant_id, dataset_binding_id)
        REFERENCES brain_dataset_bindings (tenant_id, id) ON DELETE SET NULL (dataset_binding_id),
      CONSTRAINT brain_metric_revisions_revision_positive CHECK (revision > 0),
      CONSTRAINT brain_metric_revisions_source_kind_values CHECK (source_kind IN ('base', 'connector')),
      CONSTRAINT brain_metric_revisions_status_values
        CHECK (status IN ('published', 'needs_review', 'retired')),
      CONSTRAINT brain_metric_revisions_text_present CHECK (
        btrim(grain) <> '' AND btrim(unit) <> '' AND btrim(numerator) <> ''
      ),
      CONSTRAINT brain_metric_revisions_json_shape CHECK (
        jsonb_typeof(source) = 'object' AND jsonb_typeof(spec) = 'object'
          AND jsonb_typeof(parameters) = 'array' AND jsonb_typeof(field_types) = 'object'
          AND jsonb_typeof(source_columns) = 'array' AND jsonb_typeof(addible_dimensions) = 'array'
      )
    )
    """)

    execute("""
    CREATE UNIQUE INDEX brain_metric_revisions_revision_key
      ON brain_metric_revisions (tenant_id, metric_page_id, revision)
    """)

    execute("""
    CREATE INDEX brain_metric_revisions_binding_idx
      ON brain_metric_revisions (tenant_id, dataset_binding_id) WHERE dataset_binding_id IS NOT NULL
    """)

    execute("""
    CREATE TABLE brain_entity_identifiers (
      tenant_id      uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      id             uuid NOT NULL,
      entity_page_id uuid NOT NULL,
      namespace      text NOT NULL,
      value          text NOT NULL,
      created_at     timestamptz NOT NULL,
      PRIMARY KEY (tenant_id, id),
      CONSTRAINT brain_entity_identifiers_entity_page_id_fkey FOREIGN KEY (tenant_id, entity_page_id)
        REFERENCES pages (tenant_id, id) ON DELETE CASCADE,
      CONSTRAINT brain_entity_identifiers_present CHECK (btrim(namespace) <> '' AND btrim(value) <> '')
    )
    """)

    execute("""
    CREATE UNIQUE INDEX brain_entity_identifiers_value_key
      ON brain_entity_identifiers (tenant_id, namespace, value)
    """)

    execute("""
    CREATE INDEX brain_entity_identifiers_entity_idx
      ON brain_entity_identifiers (tenant_id, entity_page_id)
    """)

    execute("""
    INSERT INTO oban_jobs (worker, queue, args, scheduled_at, state, max_attempts)
    SELECT 'Ankole.Brain.Jobs.InstallDefaultPacks', 'default',
           jsonb_build_object('tenant_id', general.tenant_id::text),
           timezone('UTC', now()), 'available'::oban_job_state, 3
    FROM brain_schema_packs general
    WHERE general.name = 'general'
      AND NOT EXISTS (
        SELECT 1 FROM brain_schema_packs data
        WHERE data.tenant_id = general.tenant_id AND data.name = 'data'
      )
    """)
  end

  def down do
    execute("DROP TABLE brain_entity_identifiers")
    execute("DROP TABLE brain_metric_revisions")
    execute("DROP TABLE brain_dataset_bindings")
  end
end
