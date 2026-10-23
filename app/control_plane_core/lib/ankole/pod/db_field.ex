defmodule Ankole.Pod.DbField do
  @moduledoc "A field definition and its schema version."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Pod

  postgres do
    table("db_fields")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:table_id, "db_fields_tenant_id_table_id_fkey"}])

    unique_index_names([
      {[:id], "db_fields_pkey"},
      {[:name], "db_fields_name_index"},
      {[:is_primary], "db_fields_one_primary_index"}
    ])

    check_constraints do
      check_constraint(:type, "db_fields_type_check")
      check_constraint(:version, "db_fields_version")
      check_constraint(:config, "db_fields_config_object")
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

    attribute(:type, :atom,
      allow_nil?: false,
      constraints: [
        one_of: [
          :text,
          :number,
          :select,
          :datetime,
          :checkbox,
          :user,
          :attachment,
          :auto_number,
          :link,
          :formula,
          :created_at,
          :updated_at,
          :created_by,
          :updated_by
        ]
      ]
    )

    attribute(:config, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{})
    attribute(:is_primary, :boolean, allow_nil?: false, default: false)
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
      accept([:id, :table_id, :name, :position, :type, :config, :is_primary])
    end

    update :update_definition do
      require_atomic?(true)
      accept([:name, :position, :type, :config])
      change(atomic_update(:version, expr(version + 1)))
    end

    destroy :remove do
      require_atomic?(true)
    end

    action :create_field, :term do
      argument(:uid, :term)
      argument(:id, :term)
      argument(:attrs, :term)
      argument(:authority, :term)
      after_commit({Ankole.Pod.Database, :committed_schema})

      run(__MODULE__.Actions)
    end

    action :update_field, :term do
      argument(:uid, :term)
      argument(:id, :term)
      argument(:attrs, :term)
      argument(:authority, :term)
      after_commit({Ankole.Pod.Database, :committed_schema})

      run(__MODULE__.Actions)
    end

    action :delete_field, :term do
      argument(:uid, :term)
      argument(:id, :term)
      argument(:version, :term)
      argument(:authority, :term)
      after_commit({Ankole.Pod.Database, :committed_schema})

      run(__MODULE__.Actions)
    end
  end

  @type t :: %__MODULE__{}
end
