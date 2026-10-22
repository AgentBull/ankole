defmodule Ankole.Principals.Agent do
  @moduledoc false
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Principals.Domain

  postgres do
    table("agents")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(handle: "agents_tenant_id_handle_index")

    foreign_key_names([
      {:uid, "agents_uid_fkey"},
      {:owner_principal_uid, "agents_owner_principal_uid_fkey"}
    ])

    unique_index_names([{[:handle], "agents_tenant_id_handle_index"}])

    check_constraints do
      check_constraint(:handle, "agents_handle_format")
      check_constraint(:role, "agents_role_present")
      check_constraint(:options, "agents_options_object")
      check_constraint(:group_memory_disclosure_mode, "agents_group_memory_disclosure_mode_check")
    end
  end

  attributes do
    attribute(:uid, Ankole.Ash.Types.PrincipalKey,
      public?: true,
      primary_key?: true,
      allow_nil?: false
    )

    attribute(:handle, :string, public?: true, allow_nil?: false)

    attribute(:type, :atom,
      public?: true,
      allow_nil?: false,
      default: :ai_colleague,
      constraints: [one_of: [:ai_colleague]]
    )

    attribute(:role, :string, public?: true, allow_nil?: false)
    attribute(:options, Ankole.Ash.Types.JSONMap, public?: true, allow_nil?: false, default: %{})

    attribute(:group_memory_disclosure_mode, :atom,
      public?: true,
      allow_nil?: false,
      default: :strict,
      constraints: [one_of: [:strict, :relaxed]]
    )

    attribute(:owner_principal_uid, Ankole.Ash.Types.PrincipalKey,
      public?: true,
      allow_nil?: false
    )

    attribute(:created_by, Ankole.Ash.Types.ActorRef, public?: true)
    timestamps(type: :utc_datetime_usec)
  end

  identities do
    identity(:handle, [:handle])
  end

  relationships do
    belongs_to :principal, Ankole.Principals.Principal do
      source_attribute(:uid)
      destination_attribute(:uid)
      define_attribute?(false)
    end

    belongs_to :owner_principal, Ankole.Principals.Principal do
      source_attribute(:owner_principal_uid)
      destination_attribute(:uid)
      define_attribute?(false)
    end
  end

  changes do
    change(fn changeset, _context ->
      case Ash.Changeset.get_attribute(changeset, :handle) do
        value when is_binary(value) ->
          Ash.Changeset.change_attribute(changeset, :handle, String.downcase(value))

        _other ->
          changeset
      end
    end)
  end

  validations do
    validate(match(:handle, ~r/\A[a-z0-9][a-z0-9._-]{0,95}\z/))
  end

  actions do
    defaults([:read])

    create :create_in_tx do
      accept([
        :uid,
        :handle,
        :type,
        :role,
        :options,
        :owner_principal_uid,
        :group_memory_disclosure_mode,
        :created_by
      ])

      transaction?(false)
    end

    in_tx_update :profile_in_tx do
      accept([
        :handle,
        :type,
        :role,
        :options,
        :owner_principal_uid,
        :group_memory_disclosure_mode,
        :created_by
      ])
    end

    in_tx_update :options_in_tx do
      accept([:options])
    end
  end

  @type t :: %__MODULE__{}
end
