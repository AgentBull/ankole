defmodule Ankole.Connectors.DbCatalogTable do
  @moduledoc "One cached table or view of an external database connection."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Connectors

  postgres do
    table("connector_db_catalog_tables")
    repo(Ankole.Repo)
    migrate?(false)

    unique_index_names([
      {[:tenant_id, :id], "connector_db_catalog_tables_tenant_id_id_key"},
      {[:tenant_id, :auth_config_id, :schema_name, :table_name],
       "connector_db_catalog_tables_name_key"}
    ])
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Kernel.gen_uuid_v7/0
    )

    attribute(:auth_config_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:schema_name, :string, allow_nil?: false, constraints: [allow_empty?: true])
    attribute(:table_name, :string, allow_nil?: false)
    attribute(:table_kind, :string, allow_nil?: false)
    attribute(:comment, :string)
    attribute(:row_estimate, :integer)
    attribute(:primary_key, {:array, :string}, allow_nil?: false, default: [])
    attribute(:sparse_order_key, {:array, :string}, allow_nil?: false, default: [])
    attribute(:query_count, :integer)

    attribute(:search_text, :string,
      allow_nil?: false,
      default: "",
      constraints: [allow_empty?: true]
    )

    attribute(:fetched_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:catalog_complete, :boolean, allow_nil?: false)
    timestamps(type: :utc_datetime_usec)
  end

  actions do
    defaults([:read])

    create :create do
      accept([
        :id,
        :auth_config_id,
        :schema_name,
        :table_name,
        :table_kind,
        :comment,
        :row_estimate,
        :primary_key,
        :sparse_order_key,
        :query_count,
        :search_text,
        :fetched_at,
        :catalog_complete
      ])
    end

    destroy :destroy do
    end
  end
end
