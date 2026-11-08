defmodule Ankole.Repo.Migrations.CreateConnectorDbCatalog do
  use Ecto.Migration

  # A rebuildable cache of external database catalogs. Each refresh replaces a
  # connection's rows; the external database stays authoritative. Every row of
  # one snapshot carries the same fetched_at and catalog_complete, which is
  # false when the refresh stopped at the catalog_tables budget.
  def up do
    execute """
    CREATE TABLE connector_db_catalog_tables (
      id uuid PRIMARY KEY,
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      auth_config_id uuid NOT NULL,
      schema_name text NOT NULL,
      table_name text NOT NULL,
      table_kind text NOT NULL,
      comment text,
      row_estimate bigint,
      primary_key text[] NOT NULL DEFAULT '{}'::text[],
      sparse_order_key text[] NOT NULL DEFAULT '{}'::text[],
      query_count bigint,
      search_text text NOT NULL DEFAULT '',
      fetched_at timestamptz NOT NULL,
      catalog_complete boolean NOT NULL,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),

      CONSTRAINT connector_db_catalog_tables_tenant_id_id_key UNIQUE (tenant_id, id),
      CONSTRAINT connector_db_catalog_tables_name_key
        UNIQUE (tenant_id, auth_config_id, schema_name, table_name),
      FOREIGN KEY (tenant_id, auth_config_id)
        REFERENCES connector_auth_configs(tenant_id, id) ON DELETE CASCADE
    )
    """

    execute """
    CREATE TABLE connector_db_catalog_columns (
      id uuid PRIMARY KEY,
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      table_id uuid NOT NULL,
      column_name text NOT NULL,
      ordinal integer NOT NULL,
      data_type text NOT NULL,
      nullable boolean NOT NULL,
      comment text,
      is_primary_key boolean NOT NULL DEFAULT false,
      is_unique boolean NOT NULL DEFAULT false,
      sparse_order_key boolean NOT NULL DEFAULT false,
      foreign_key jsonb,
      sensitive boolean NOT NULL DEFAULT false,
      profile jsonb,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),

      CONSTRAINT connector_db_catalog_columns_name_key UNIQUE (tenant_id, table_id, column_name),
      FOREIGN KEY (tenant_id, table_id)
        REFERENCES connector_db_catalog_tables(tenant_id, id) ON DELETE CASCADE
    )
    """

    execute """
    CREATE INDEX connector_db_catalog_tables_bm25_idx
      ON connector_db_catalog_tables
      USING bm25 (id, tenant_id, auth_config_id, (search_text::pdb.icu))
      WITH (key_field='id')
    """
  end

  def down do
    execute "DROP TABLE connector_db_catalog_columns"
    execute "DROP TABLE connector_db_catalog_tables"
  end
end
