defmodule Ankole.Pod.DbRecord do
  @moduledoc "A record with independent field versions and immutable creation facts."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.Pod.Domain,
    tenant_in_primary_key: true

  postgres do
    table("db_records")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:table_id, "db_records_tenant_id_table_id_fkey"}])
    unique_index_names([{[:table_id, :id], "db_records_pkey"}])

    check_constraints do
      check_constraint(:data, "db_records_value_objects")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:table_id, Ankole.Ash.Types.UUIDv7, primary_key?: true, allow_nil?: false)
    attribute(:data, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{})
    attribute(:versions, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{})
    attribute(:created_by, Ankole.Ash.Types.ActorRef, allow_nil?: false)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:updated_by, Ankole.Ash.Types.ActorRef, allow_nil?: false)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false)
  end

  relationships do
    belongs_to :table, Ankole.Pod.DbTable do
      define_attribute?(false)
      source_attribute(:table_id)
      destination_attribute(:id)
      allow_nil?(false)
    end
  end

  actions do
    defaults([:read])

    create :create_in_tx do
      transaction?(false)
      change(Ankole.Ash.RequireTransaction)

      accept([
        :id,
        :table_id,
        :data,
        :versions,
        :created_by,
        :created_at,
        :updated_by,
        :updated_at
      ])
    end

    atomic_in_tx_update :update_values do
      accept([:data, :versions, :updated_by, :updated_at])
    end

    destroy :remove do
      transaction?(false)
      require_atomic?(true)
      change(Ankole.Ash.RequireTransaction.Atomic)
    end
  end

  @type t :: %__MODULE__{}
end
