defmodule Ankole.AuthZ.Grant do
  @moduledoc "Permission grant owned by one Principal or one Principal group."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.AuthZ

  @fields [
    :principal_uid,
    :group_id,
    :resource_pattern,
    :action,
    :condition,
    :description,
    :metadata
  ]

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
    change(fn changeset, _context ->
      if is_nil(Ash.Changeset.get_attribute(changeset, :condition)),
        do: Ash.Changeset.force_change_attribute(changeset, :condition, "true"),
        else: changeset
    end)
  end

  validations do
    validate(fn changeset, _context ->
      case {Ash.Changeset.get_attribute(changeset, :principal_uid),
            Ash.Changeset.get_attribute(changeset, :group_id)} do
        {principal_uid, nil} when is_binary(principal_uid) -> :ok
        {nil, group_id} when is_binary(group_id) -> :ok
        {nil, nil} -> {:error, field: :principal_uid, message: "or group_id is required"}
        {_principal_uid, _group_id} -> {:error, field: :group_id, message: "must be blank"}
      end
    end)

    validate(fn changeset, _context ->
      case Ash.Changeset.get_attribute(changeset, :action) do
        action when is_binary(action) ->
          if String.contains?(action, ":"),
            do: {:error, field: :action, message: "must not contain colon"},
            else: :ok

        _action ->
          :ok
      end
    end)

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

    action :create_permission_grant, :struct do
      constraints(instance_of: __MODULE__)
      argument(:attrs, :map, allow_nil?: false)

      run(fn input, _context ->
        Ankole.AuthZ.Grants.create_permission_grant(Ankole.Repo, input.arguments.attrs)
        |> Ankole.Errors.wrap()
      end)
    end

    action :upsert_permission_grant, :struct do
      constraints(instance_of: __MODULE__)
      argument(:attrs, :map, allow_nil?: false)

      run(fn input, _context ->
        Ankole.AuthZ.Grants.upsert_permission_grant(Ankole.Repo, input.arguments.attrs)
        |> Ankole.Errors.wrap()
      end)
    end

    action :delete_permission_grant, :struct do
      constraints(instance_of: __MODULE__)
      argument(:id, :term, allow_nil?: false)

      run(fn input, _context ->
        Ankole.AuthZ.Grants.delete_permission_grant(Ankole.Repo, input.arguments.id)
        |> Ankole.Errors.wrap()
      end)
    end

    action :update_permission_grant, :struct do
      constraints(instance_of: __MODULE__)
      argument(:grant, :struct, allow_nil?: false, constraints: [instance_of: __MODULE__])
      argument(:attrs, :map, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Repo
        |> Ankole.AuthZ.Grants.update_permission_grant(
          input.arguments.grant,
          input.arguments.attrs
        )
        |> Ankole.Errors.wrap()
      end)
    end
  end

  @type t :: %__MODULE__{}
end
