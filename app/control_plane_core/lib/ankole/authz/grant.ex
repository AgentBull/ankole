defmodule Ankole.AuthZ.Grant do
  @moduledoc "Permission grant owned by one Principal or one Principal group."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.AuthZ,
    extensions: [AshJsonApi.Resource]

  require Ash.Query

  @fields [
    :principal_uid,
    :group_id,
    :resource_pattern,
    :action,
    :condition,
    :description,
    :metadata
  ]

  json_api do
    type("permission_grant")
    derive_filter?(false)
    derive_sort?(false)

    default_fields([
      :principal_uid,
      :group_id,
      :resource_pattern,
      :action,
      :condition,
      :description
    ])
  end

  postgres do
    table("permission_grants")
    repo(Ankole.Repo)
    migrate?(false)

    identity_index_names(
      principal_rule: "permission_grants_principal_natural_index",
      group_rule: "permission_grants_group_natural_index"
    )

    foreign_key_names([
      {:principal_uid, "permission_grants_principal_uid_fkey"},
      {:group_id, "permission_grants_group_id_fkey"}
    ])

    unique_index_names([
      {[:principal_uid, :resource_pattern, :action, :condition],
       "permission_grants_principal_natural_index"},
      {[:group_id, :resource_pattern, :action, :condition],
       "permission_grants_group_natural_index"}
    ])

    identity_wheres_to_sql(
      principal_rule: "principal_uid IS NOT NULL",
      group_rule: "group_id IS NOT NULL"
    )

    check_constraints do
      check_constraint(:principal_uid, "permission_grants_owner_shape")
      check_constraint(:resource_pattern, "permission_grants_resource_pattern_present")
      check_constraint(:action, "permission_grants_action_present")
      check_constraint(:action, "permission_grants_action_no_colon")
      check_constraint(:condition, "permission_grants_condition_present")
      check_constraint(:metadata, "permission_grants_metadata_object")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      public?: true,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:principal_uid, Ankole.Ash.Types.PrincipalKey, public?: true)
    attribute(:group_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:resource_pattern, :string, public?: true, allow_nil?: false)
    attribute(:action, :string, public?: true, allow_nil?: false)
    attribute(:condition, :string, public?: true, allow_nil?: false, default: "true")
    attribute(:description, :string, public?: true)
    attribute(:metadata, Ankole.Ash.Types.JSONMap, public?: true, allow_nil?: false, default: %{})
    timestamps(type: :utc_datetime_usec)
  end

  identities do
    identity(:principal_rule, [:principal_uid, :resource_pattern, :action, :condition],
      all_tenants?: true,
      where: expr(not is_nil(principal_uid))
    )

    identity(:group_rule, [:group_id, :resource_pattern, :action, :condition],
      all_tenants?: true,
      where: expr(not is_nil(group_id))
    )
  end

  relationships do
    belongs_to :principal, Ankole.Principals.Principal do
      source_attribute(:principal_uid)
      destination_attribute(:uid)
      define_attribute?(false)
    end

    belongs_to(:group, Ankole.AuthZ.Group, define_attribute?: false)
  end

  changes do
    change(set_attribute(:condition, "true"), where: [attribute_equals(:condition, nil)])
  end

  validations do
    validate(attribute_does_not_equal(:principal_uid, nil),
      where: [attribute_equals(:group_id, nil)],
      message: "or group_id is required"
    )

    validate(attribute_equals(:group_id, nil),
      where: [attribute_does_not_equal(:principal_uid, nil)],
      message: "must be blank"
    )

    validate(match(:action, ~r/\A[^:]*\z/), message: "must not contain colon")

    validate(
      {Ankole.AuthZ.Validations.Syntax, attribute: :resource_pattern, kind: :resource_pattern},
      only_when_valid?: true
    )

    validate({Ankole.AuthZ.Validations.Syntax, attribute: :condition, kind: :condition},
      only_when_valid?: true
    )
  end

  actions do
    defaults([:read])

    read :by_id do
      description("Reads one row by ID. An ID that is not a UUID matches no row.")
      argument(:id, :string, allow_nil?: false)
      get?(true)

      prepare(fn query, _context ->
        case Ecto.UUID.cast(Ash.Query.get_argument(query, :id)) do
          {:ok, id} -> Ash.Query.filter(query, id == ^id)
          :error -> Ash.Query.filter(query, false)
        end
      end)
    end

    read :of_principal do
      description("Lists the grants that one Principal owns directly.")
      argument(:uid, :string, allow_nil?: false)
      filter(expr(principal_uid == ^arg(:uid)))
      prepare(build(sort: [resource_pattern: :asc, action: :asc]))
    end

    read :of_group do
      description("Lists the grants that one group owns.")
      argument(:name, :string, allow_nil?: false)
      filter(expr(group.name == ^arg(:name)))
      prepare(build(sort: [resource_pattern: :asc, action: :asc]))
    end

    create :create_in_tx do
      accept(@fields)
    end

    create :upsert_in_tx do
      accept(@fields)
      upsert?(true)
      upsert_fields([:description, :metadata, :updated_at])
    end

    update :update_in_tx do
      accept(@fields)
    end

    destroy(:delete_in_tx)

    action :create_operator_grant, :struct do
      description("Creates a grant for a Principal or a group. A Pod page action is refused.")
      constraints(instance_of: __MODULE__)
      argument(:principal_uid, :string)
      argument(:group_name, :string)
      argument(:resource_pattern, :string, allow_nil?: false)
      argument(:action, :string, allow_nil?: false)
      argument(:condition, :string)
      argument(:description, :string)

      run(__MODULE__.Actions)
    end

    action :update_operator_grant, :struct do
      description("Updates a grant. A Pod page grant can change only its description.")
      constraints(instance_of: __MODULE__)
      argument(:id, :string, allow_nil?: false)
      argument(:resource_pattern, :string)
      argument(:action, :string)
      argument(:condition, :string)
      argument(:description, :string)

      run(__MODULE__.Actions)
    end

    action :delete_operator_grant, :struct do
      description("Deletes a grant. A Pod page grant is refused.")
      constraints(instance_of: __MODULE__)
      argument(:id, :string, allow_nil?: false)

      run(__MODULE__.Actions)
    end
  end

  @type t :: %__MODULE__{}
end
