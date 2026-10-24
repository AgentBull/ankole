defmodule Ankole.Pod.DbView do
  @moduledoc "A table view and its schema version."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Pod, extensions: [AshJsonApi.Resource]

  json_api do
    type("pod_db_view")
    derive_filter?(false)
    derive_sort?(false)
  end

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
      public?: true,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:table_id, Ankole.Ash.Types.UUIDv7, public?: true, allow_nil?: false)
    attribute(:name, :string, public?: true, allow_nil?: false, constraints: [trim?: false])
    attribute(:position, :string, public?: true, allow_nil?: false, constraints: [trim?: false])

    attribute(:type, :atom,
      public?: true,
      allow_nil?: false,
      constraints: [one_of: [:grid, :kanban, :gallery]]
    )

    attribute(:config, Ankole.Ash.Types.JSONMap, public?: true, allow_nil?: false, default: %{})

    attribute(:version, :integer,
      public?: true,
      allow_nil?: false,
      default: 1,
      constraints: [min: 1]
    )
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
      accept([:id, :table_id, :name, :position, :type, :config])
    end

    update :update_definition do
      require_atomic?(true)
      accept([:name, :position, :type, :config])
      change(atomic_update(:version, expr(version + 1)))
    end

    destroy :remove do
      require_atomic?(true)
    end
  end

  @type t :: %__MODULE__{}
end
