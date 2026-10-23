defmodule Ankole.AuthZ.Group do
  @moduledoc "Principal group used by the AuthZ rule engine."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.AuthZ

  @fields [
    :name,
    :display_name,
    :domain,
    :kind,
    :built_in,
    :computed_condition,
    :description,
    :metadata
  ]

  postgres do
    table("principal_groups")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(name: "principal_groups_name_index")
    unique_index_names([{[:name], "principal_groups_name_index"}])

    check_constraints do
      check_constraint(:name, "principal_groups_name_present")
      check_constraint(:name, "principal_groups_name_lowercase")
      check_constraint(:display_name, "principal_groups_display_name_present")
      check_constraint(:computed_condition, "principal_groups_computed_condition_by_kind")
      check_constraint(:domain, "principal_groups_computed_domain")
      check_constraint(:metadata, "principal_groups_metadata_object")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      public?: true,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:name, :string, public?: true, allow_nil?: false)
    attribute(:display_name, :string, public?: true, allow_nil?: false)

    attribute(:domain, :atom,
      public?: true,
      allow_nil?: false,
      default: :operator,
      constraints: [one_of: [:operator, :directory, :im_group, :signal_source]]
    )

    attribute(:kind, :atom,
      public?: true,
      allow_nil?: false,
      default: :static,
      constraints: [one_of: [:static, :computed]]
    )

    attribute(:built_in, :boolean, public?: true, allow_nil?: false, default: false)
    attribute(:computed_condition, :string, public?: true)
    attribute(:description, :string, public?: true)
    attribute(:metadata, Ankole.Ash.Types.JSONMap, public?: true, allow_nil?: false, default: %{})
    timestamps(type: :utc_datetime_usec)
  end

  identities do
    identity(:name, [:name])
  end

  relationships do
    has_many(:memberships, Ankole.AuthZ.Membership, destination_attribute: :group_id)
    has_many(:external_bindings, Ankole.AuthZ.ExternalBinding, destination_attribute: :group_id)
    has_many(:grants, Ankole.AuthZ.Grant, destination_attribute: :group_id)
  end

  aggregates do
    count(:member_count, :memberships)
    count(:grant_count, :grants)
  end

  changes do
    change(fn changeset, _context ->
      case Ash.Changeset.get_attribute(changeset, :name) do
        name when is_binary(name) ->
          Ash.Changeset.change_attribute(changeset, :name, String.downcase(name))

        _name ->
          changeset
      end
    end)
  end

  validations do
    validate(absent(:computed_condition), where: [attribute_equals(:kind, :static)])
    validate(present(:computed_condition), where: [attribute_equals(:kind, :computed)])

    validate(attribute_equals(:domain, :operator),
      where: [attribute_equals(:kind, :computed)],
      message: "must be operator for computed groups"
    )

    validate({Ankole.AuthZ.Validations.Syntax, attribute: :computed_condition, kind: :condition},
      where: [attribute_equals(:kind, :computed)],
      only_when_valid?: true
    )
  end

  actions do
    defaults([:read])

    create :create_in_tx do
      accept(@fields)
    end

    create :ensure_in_tx do
      accept(@fields)
      upsert?(true)
      upsert_identity(:name)
      upsert_fields([:name])
    end

    update :profile_in_tx do
      accept(@fields -- [:built_in])

      validate(fn changeset, _context ->
        immutable =
          if changeset.data.built_in,
            do:
              Enum.filter([:name, :kind, :computed_condition], fn field ->
                Ash.Changeset.changing_attribute?(changeset, field)
              end),
            else: []

        case immutable do
          [] -> :ok
          fields -> {:error, fields: fields, message: "cannot change a built-in group"}
        end
      end)
    end

    destroy(:delete_in_tx)

    action :ensure_synced_member, :atom do
      argument(:group_attrs, :map, allow_nil?: false)
      argument(:principal_uid, :term, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Repo
        |> Ankole.AuthZ.ensure_synced_group_member_in_tx(
          input.arguments.group_attrs,
          input.arguments.principal_uid
        )
        |> case do
          :ok -> {:ok, :ensured}
          error -> Ankole.Errors.wrap(error)
        end
      end)
    end

    action :delete_operator_group, :struct do
      constraints(instance_of: __MODULE__)
      argument(:id_or_name, :term, allow_nil?: false)

      run(fn input, _context ->
        Ankole.AuthZ.Store.delete_operator_group(Ankole.Repo, input.arguments.id_or_name)
        |> Ankole.Errors.wrap()
      end)
    end

    action :add_member, :struct do
      constraints(instance_of: Ankole.AuthZ.Membership)
      argument(:principal_uid, :term, allow_nil?: false)
      argument(:group, :term, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Repo
        |> Ankole.AuthZ.Store.add_principal_to_group(
          input.arguments.principal_uid,
          input.arguments.group,
          Ankole.AuthZ.Root.admin_group_name()
        )
        |> Ankole.Errors.wrap()
      end)
    end

    action :remove_member, :atom do
      argument(:principal_uid, :term, allow_nil?: false)
      argument(:group, :term, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Repo
        |> Ankole.AuthZ.Store.remove_principal_from_group(
          input.arguments.principal_uid,
          input.arguments.group,
          Ankole.AuthZ.Root.admin_group_name()
        )
        |> Ankole.Errors.wrap()
      end)
    end

    action :add_synced_member, :struct do
      constraints(instance_of: Ankole.AuthZ.Membership)
      argument(:group_id, :term, allow_nil?: false)
      argument(:domain, :atom, constraints: [one_of: [:directory, :im_group, :signal_source]])
      argument(:principal_uid, :term, allow_nil?: false)

      run(fn %{arguments: args}, _context ->
        Ankole.Repo
        |> Ankole.AuthZ.Store.add_synced_group_member(
          args.group_id,
          args.domain,
          args.principal_uid
        )
        |> Ankole.Errors.wrap()
      end)
    end

    action :remove_synced_member, :atom do
      argument(:group_id, :term, allow_nil?: false)
      argument(:domain, :atom, constraints: [one_of: [:directory, :im_group, :signal_source]])
      argument(:principal_uid, :term, allow_nil?: false)

      run(fn %{arguments: args}, _context ->
        Ankole.Repo
        |> Ankole.AuthZ.Store.remove_synced_group_member(
          args.group_id,
          args.domain,
          args.principal_uid
        )
        |> Ankole.Errors.wrap()
      end)
    end

    action :replace_static_members, :map do
      argument(:group_id, :term, allow_nil?: false)
      argument(:expected_domain, :atom, allow_nil?: false)
      argument(:principal_uids, {:array, :term}, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Repo
        |> Ankole.AuthZ.Store.replace_static_group_members(
          input.arguments.group_id,
          input.arguments.expected_domain,
          input.arguments.principal_uids
        )
        |> Ankole.Errors.wrap()
      end)
    end

    action :apply_static_member_delta, :map do
      argument(:group_id, :term, allow_nil?: false)
      argument(:expected_domain, :atom, allow_nil?: false)
      argument(:added_uids, {:array, :term}, allow_nil?: false)
      argument(:removed_uids, {:array, :term}, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Repo
        |> Ankole.AuthZ.Store.apply_static_group_member_delta(
          input.arguments.group_id,
          input.arguments.expected_domain,
          input.arguments.added_uids,
          input.arguments.removed_uids
        )
        |> Ankole.Errors.wrap()
      end)
    end
  end

  @type t :: %__MODULE__{}
end
