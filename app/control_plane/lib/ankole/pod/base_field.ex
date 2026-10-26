defmodule Ankole.Pod.BaseField do
  @moduledoc "A field definition and its schema version."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Pod, extensions: [AshJsonApi.Resource]

  json_api do
    type("pod_base_field")
    derive_filter?(false)
    derive_sort?(false)
  end

  postgres do
    table("base_fields")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:table_id, "base_fields_tenant_id_table_id_fkey"}])

    unique_index_names([
      {[:id], "base_fields_pkey"},
      {[:name], "base_fields_name_index"},
      {[:is_primary], "base_fields_one_primary_index"}
    ])

    check_constraints do
      check_constraint(:type, "base_fields_type_check")
      check_constraint(:type, "base_fields_primary_text")
      check_constraint(:version, "base_fields_version")
      check_constraint(:config, "base_fields_config_object")
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

    attribute(:config, Ankole.Ash.Types.JSONMap, public?: true, allow_nil?: false, default: %{})
    attribute(:is_primary, :boolean, public?: true, allow_nil?: false, default: false)

    attribute(:version, :integer,
      public?: true,
      allow_nil?: false,
      default: 1,
      constraints: [min: 1]
    )
  end

  relationships do
    belongs_to :table, Ankole.Pod.BaseTable do
      define_attribute?(false)
      source_attribute(:table_id)
      destination_attribute(:id)
      allow_nil?(false)
    end
  end

  validations do
    validate(attribute_equals(:type, :text),
      where: [attribute_equals(:is_primary, true)],
      message: "Primary fields must use the text type"
    )
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
  end

  @type t :: %__MODULE__{}
end
