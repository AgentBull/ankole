defmodule Ankole.Brain.Schemas.DatasetBinding do
  @moduledoc """
  The executable binding of one `datasets/` object to a Base table or a
  connector table. A save of the dataset object replaces its binding.
  """
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Brain

  postgres do
    table("brain_dataset_bindings")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(dataset: "brain_dataset_bindings_dataset_key")
    foreign_key_names([{:dataset_page_id, "brain_dataset_bindings_dataset_page_id_fkey"}])

    check_constraints do
      check_constraint(:source_kind, "brain_dataset_bindings_source_kind_values")
      check_constraint(:source_kind, "brain_dataset_bindings_source_shape")
      check_constraint(:grain, "brain_dataset_bindings_grain_present")
      check_constraint(:primary_key, "brain_dataset_bindings_json_shape")
    end
  end

  @source [
    :source_kind,
    :base_page_id,
    :base_table_id,
    :connection_slug,
    :source_catalog,
    :source_schema,
    :source_table,
    :grain,
    :primary_key,
    :business_key,
    :entity_key,
    :joins,
    :field_types
  ]

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:dataset_page_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:source_kind, :atom, allow_nil?: false, constraints: [one_of: [:base, :connector]])
    attribute(:base_page_id, Ankole.Ash.Types.UUIDv7)
    attribute(:base_table_id, Ankole.Ash.Types.UUIDv7)
    attribute(:connection_slug, :string, constraints: [trim?: false])
    attribute(:source_catalog, :string, constraints: [trim?: false])
    attribute(:source_schema, :string, constraints: [trim?: false])
    attribute(:source_table, :string, constraints: [trim?: false])
    attribute(:grain, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:primary_key, Ankole.Ash.Types.JSONList, allow_nil?: false, default: [])
    attribute(:business_key, Ankole.Ash.Types.JSONList, allow_nil?: false, default: [])
    attribute(:entity_key, Ankole.Ash.Types.JSONMap)
    attribute(:joins, Ankole.Ash.Types.JSONList, allow_nil?: false, default: [])
    attribute(:field_types, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{})
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
  end

  identities do
    identity(:dataset, [:dataset_page_id])
  end

  actions do
    defaults([:read])

    create :bind do
      accept([:id, :dataset_page_id, :created_at, :updated_at | @source])
    end

    update :rebind do
      require_atomic?(true)
      accept(@source)
      change(set_attribute(:updated_at, &DateTime.utc_now/0))
    end

    destroy :remove do
      require_atomic?(true)
    end
  end

  @type t :: %__MODULE__{}
end
