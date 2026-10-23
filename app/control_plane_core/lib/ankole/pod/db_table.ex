defmodule Ankole.Pod.DbTable do
  @moduledoc "A data table and its atomic record counters."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Pod

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
      accept([:id, :page_id, :name, :position])
    end

    update :commit_write do
      require_atomic?(true)
      accept([])
      argument(:delta, :integer, allow_nil?: false)
      argument(:inserted, :integer, allow_nil?: false, constraints: [min: 0])
      change(atomic_update(:data_version, expr(data_version + 1)))
      change(atomic_update(:record_count, expr(record_count + ^arg(:delta))))
      change(atomic_update(:next_auto_number, expr(next_auto_number + ^arg(:inserted))))
    end

    update :initialize_copy do
      require_atomic?(true)
      accept([:record_count, :next_auto_number])
      change(filter(expr(data_version == 0 and record_count == 0 and next_auto_number == 1)))
      change(set_attribute(:data_version, 1))
    end

    destroy :remove do
      require_atomic?(true)
    end

    action :create_table, :term do
      argument(:uid, :term)
      argument(:page_id, :term)
      argument(:attrs, :term)
      argument(:authority, :term)

      run(__MODULE__.Actions)
    end

    # Reads under a shared table lock with the query time and timezone limits.
    action :read_table, :term do
      argument(:uid, :term)
      argument(:id, :term)

      run(__MODULE__.Actions)
    end

    action :query_records, :term do
      argument(:uid, :term)
      argument(:id, :term)
      argument(:attrs, :term)

      run(__MODULE__.Actions)
    end

    action :aggregate_records, :term do
      argument(:uid, :term)
      argument(:id, :term)
      argument(:attrs, :term)

      run(__MODULE__.Actions)
    end

    action :write_records, :term do
      argument(:uid, :term)
      argument(:id, :term)
      argument(:attrs, :term)
      argument(:authority, :term)
      after_commit({Ankole.Pod.Database, :committed_records})

      run(__MODULE__.Actions)
    end

    action :copy_table, :term do
      argument(:uid, :term)
      argument(:id, :term)
      argument(:attrs, :term)
      argument(:authority, :term)
      after_commit({Ankole.Pod.Copy, :committed})

      run(__MODULE__.Actions)
    end
  end

  @type t :: %__MODULE__{}
end
