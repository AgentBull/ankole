defmodule Ankole.Pod.DbView do
  @moduledoc "A table view and its schema version."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Pod.Domain

  postgres do
    table("db_views")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:table_id, "db_views_tenant_id_table_id_fkey"}])
    unique_index_names([{[:id], "db_views_pkey"}])

    check_constraints do
      check_constraint(:type, "db_views_type_check")
      check_constraint(:version, "db_views_version")
      check_constraint(:config, "db_views_config_object")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:table_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:name, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:position, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:type, :atom, allow_nil?: false, constraints: [one_of: [:grid, :kanban, :gallery]])
    attribute(:config, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{})
    attribute(:version, :integer, allow_nil?: false, default: 1, constraints: [min: 1])
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
      accept([:id, :table_id, :name, :position, :type, :config])
    end

    atomic_in_tx_update :update_definition do
      accept([:name, :position, :type, :config])
      change(atomic_update(:version, expr(version + 1)))
    end

    destroy :remove do
      transaction?(false)
      require_atomic?(true)
      change(Ankole.Ash.RequireTransaction.Atomic)
    end
  end

  @type t :: %__MODULE__{}
end
