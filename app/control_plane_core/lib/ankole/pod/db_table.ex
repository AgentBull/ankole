defmodule Ankole.Pod.DbTable do
  @moduledoc "A data table and its atomic record counters."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Pod.Domain

  postgres do
    table("db_tables")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:page_id, "db_tables_tenant_id_page_id_fkey"}])
    unique_index_names([{[:id], "db_tables_pkey"}])

    check_constraints do
      check_constraint(:record_count, "db_tables_counters")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:page_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:name, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:position, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:data_version, :integer, allow_nil?: false, default: 0, constraints: [min: 0])
    attribute(:record_count, :integer, allow_nil?: false, default: 0, constraints: [min: 0])
    attribute(:next_auto_number, :integer, allow_nil?: false, default: 1, constraints: [min: 1])
  end

  def record_limit, do: 100_000

  actions do
    defaults([:read])

    create :create_in_tx do
      transaction?(false)
      accept([:id, :page_id, :name, :position])
    end

    atomic_in_tx_update :commit_write do
      accept([])
      argument(:delta, :integer, allow_nil?: false)
      argument(:inserted, :integer, allow_nil?: false, constraints: [min: 0])
      change(atomic_update(:data_version, expr(data_version + 1)))
      change(atomic_update(:record_count, expr(record_count + ^arg(:delta))))
      change(atomic_update(:next_auto_number, expr(next_auto_number + ^arg(:inserted))))
    end

    atomic_in_tx_update :initialize_copy do
      accept([:record_count, :next_auto_number])
      change(filter(expr(data_version == 0 and record_count == 0 and next_auto_number == 1)))
      change(set_attribute(:data_version, 1))
    end

    destroy :remove do
      transaction?(false)
      require_atomic?(true)
    end
  end

  @type t :: %__MODULE__{}
end
