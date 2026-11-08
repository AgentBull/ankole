defmodule Ankole.Connectors.DbCatalogColumn do
  @moduledoc "One cached column of an external database table, with its masked profile."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Connectors

  postgres do
    table("connector_db_catalog_columns")
    repo(Ankole.Repo)
    migrate?(false)

    unique_index_names([
      {[:tenant_id, :table_id, :column_name], "connector_db_catalog_columns_name_key"}
    ])
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Kernel.gen_uuid_v7/0
    )

    attribute(:table_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:column_name, :string, allow_nil?: false)
    attribute(:ordinal, :integer, allow_nil?: false)
    attribute(:data_type, :string, allow_nil?: false)
    attribute(:nullable, :boolean, allow_nil?: false)
    attribute(:comment, :string)
    attribute(:is_primary_key, :boolean, allow_nil?: false, default: false)
    attribute(:is_unique, :boolean, allow_nil?: false, default: false)
    attribute(:sparse_order_key, :boolean, allow_nil?: false, default: false)
    attribute(:foreign_key, Ankole.Ash.Types.JSONMap)
    attribute(:sensitive, :boolean, allow_nil?: false, default: false)
    attribute(:profile, Ankole.Ash.Types.JSONMap)
    timestamps(type: :utc_datetime_usec)
  end

  actions do
    defaults([:read])

    create :create do
      accept([
        :id,
        :table_id,
        :column_name,
        :ordinal,
        :data_type,
        :nullable,
        :comment,
        :is_primary_key,
        :is_unique,
        :sparse_order_key,
        :foreign_key,
        :sensitive,
        :profile
      ])
    end

    update :mask do
      require_atomic?(true)
      accept([])
      change(set_attribute(:sensitive, true))
      change(set_attribute(:profile, nil))
    end
  end
end
