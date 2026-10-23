defmodule Ankole.AuthZ.Group do
  @moduledoc "Principal group used by the AuthZ rule engine."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.AuthZ,
    extensions: [AshJsonApi.Resource]

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

  # The Principal fields of one group member in the Console API.
  @member_fields [
    uid: [type: :string, allow_nil?: false],
    type: [type: :atom, allow_nil?: false, constraints: [one_of: [:human, :agent, :system]]],
    status: [type: :atom, allow_nil?: false, constraints: [one_of: [:active, :disabled]]],
    display_name: [type: :string],
    avatar_url: [type: :string],
    member_since: [type: :utc_datetime_usec]
  ]

  json_api do
    type("principal_group")
    derive_filter?(false)
    derive_sort?(false)

    default_fields([
      :name,
      :display_name,
      :domain,
      :kind,
      :built_in,
      :computed_condition,
      :description,
      :member_count,
      :grant_count
    ])
  end

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
    count(:member_count, :memberships, public?: true)
    count(:grant_count, :grants, public?: true)
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

    read :console_list do
      prepare(build(sort: [name: :asc]))
    end

    read :of_principal do
      description("Lists the static groups of one Principal.")
      argument(:uid, :string, allow_nil?: false)
      filter(expr(exists(memberships, principal_uid == ^arg(:uid))))
      prepare(build(sort: [name: :asc]))
    end

    create :create do
      description("Creates an operator group.")
      accept([:name, :display_name, :kind, :computed_condition, :description])
    end

    update :profile_in_tx do
      accept(@fields -- [:built_in])
      validate(&__MODULE__.keep_built_in/2)
    end

    update :update do
      description("Updates the display fields or the condition of a group.")
      accept([:display_name, :computed_condition, :description])
      validate(&__MODULE__.keep_built_in/2)
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
      description("Deletes an operator group that has no grants.")
      constraints(instance_of: __MODULE__)
      argument(:name, :string, allow_nil?: false, description: "The group name or ID.")

      run(fn input, _context ->
        Ankole.AuthZ.Store.delete_operator_group(Ankole.Repo, input.arguments.name)
        |> Ankole.Errors.not_found(__MODULE__)
        |> Ankole.Errors.wrap()
      end)
    end

    action :list_members, {:array, :map} do
      description("Lists the effective members of a group.")
      constraints(items: [fields: @member_fields])
      argument(:name, :string, allow_nil?: false)

      run(fn input, _context ->
        input.arguments.name
        |> Ankole.AuthZ.effective_group_members()
        |> Ankole.Errors.not_found(__MODULE__)
        |> Ankole.Errors.wrap()
      end)
    end

    action :preview_computed_members, {:array, :map} do
      description("Lists the active Principals that a computed group condition matches.")
      constraints(items: [fields: @member_fields])
      argument(:condition, :string, allow_nil?: false)

      run(fn input, _context ->
        input.arguments.condition |> Ankole.AuthZ.preview_members() |> Ankole.Errors.wrap()
      end)
    end

    action :add_member, :struct do
      description("Adds a Principal to a static operator group.")
      constraints(instance_of: Ankole.AuthZ.Membership)
      argument(:principal_uid, :string, allow_nil?: false)
      argument(:name, :string, allow_nil?: false, description: "The group name or ID.")

      run(fn input, _context ->
        Ankole.Repo
        |> Ankole.AuthZ.Store.add_principal_to_group(
          input.arguments.principal_uid,
          input.arguments.name,
          Ankole.AuthZ.Root.admin_group_name()
        )
        |> Ankole.Errors.not_found(__MODULE__)
        |> Ankole.Errors.wrap()
      end)
    end

    action :remove_member, :atom do
      description("Removes a Principal from a static operator group.")
      argument(:principal_uid, :string, allow_nil?: false)
      argument(:name, :string, allow_nil?: false, description: "The group name or ID.")

      run(fn input, _context ->
        Ankole.Repo
        |> Ankole.AuthZ.Store.remove_principal_from_group(
          input.arguments.principal_uid,
          input.arguments.name,
          Ankole.AuthZ.Root.admin_group_name()
        )
        |> Ankole.Errors.not_found(__MODULE__)
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

  @doc false
  # A built-in group keeps its name, kind, and condition.
  def keep_built_in(changeset, _context) do
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
  end

  @type t :: %__MODULE__{}
end
