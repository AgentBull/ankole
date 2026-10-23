defmodule Ankole.Principals.Agent do
  @moduledoc """
  The agent subtype of a Principal.

  The Console reads an Agent with the status, the name, and the avatar of its
  Principal and the provider of its Worker. A Console write runs one generic
  action that changes the Principal and the Agent rows in one transaction.
  """
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.Principals,
    extensions: [AshJsonApi.Resource]

  alias Ankole.Principals.AgentConsole

  json_api do
    type("agent")
    derive_filter?(false)
    derive_sort?(false)

    # The primary key names the record in the result of a generic action.
    default_fields([
      :uid,
      :handle,
      :worker_provider_id,
      :status,
      :display_name,
      :avatar_url,
      :role,
      :options,
      :owner_principal_uid,
      :group_memory_disclosure_mode,
      :created_by,
      :inserted_at,
      :updated_at
    ])
  end

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
    timestamps(type: :utc_datetime_usec, public?: true)
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

  calculations do
    calculate(:status, :atom, expr(principal.status),
      public?: true,
      constraints: [one_of: [:active, :disabled]]
    )

    calculate(:display_name, :string, expr(principal.display_name), public?: true)
    calculate(:avatar_url, :string, expr(principal.avatar_url), public?: true)

    calculate(:worker_provider_id, :string, Ankole.Principals.Agent.WorkerProviderID,
      public?: true
    )
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

    read :console_list do
      prepare(build(sort: [inserted_at: :asc]))
    end

    action :console_create, :struct do
      constraints(instance_of: __MODULE__)
      argument(:handle, :string, allow_nil?: false)
      argument(:display_name, :string, allow_nil?: false)
      argument(:avatar_url, :string)
      argument(:role, :string, allow_nil?: false)
      argument(:options, Ankole.Ash.Types.JSONMap)
      argument(:owner_principal_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false)

      argument(:group_memory_disclosure_mode, :atom, constraints: [one_of: [:strict, :relaxed]])

      argument(:worker_provider_id, :string)

      run(fn input, _context ->
        input.arguments
        |> AgentConsole.create_in_tx(input.context.principal)
        |> Ankole.Errors.wrap(&AgentConsole.rejection/1)
      end)
    end

    action :console_update, :struct do
      constraints(instance_of: __MODULE__)
      argument(:uid, :string, allow_nil?: false)
      argument(:handle, :string)
      argument(:display_name, :string)
      argument(:avatar_url, :string)
      argument(:role, :string)
      argument(:options, Ankole.Ash.Types.JSONMap)
      argument(:owner_principal_uid, Ankole.Ash.Types.PrincipalKey)

      argument(:group_memory_disclosure_mode, :atom, constraints: [one_of: [:strict, :relaxed]])

      run(fn input, _context ->
        input.arguments
        |> AgentConsole.update_in_tx()
        |> Ankole.Errors.wrap(&AgentConsole.rejection/1)
      end)
    end

    action :console_enable, :struct do
      constraints(instance_of: __MODULE__)
      argument(:uid, :string, allow_nil?: false)
      after_commit({AgentConsole, :publish_enable})

      run(fn input, _context ->
        input.arguments.uid |> AgentConsole.enable_in_tx() |> Ankole.Errors.wrap()
      end)
    end

    action :console_delete, :struct do
      constraints(instance_of: __MODULE__)
      argument(:uid, :string, allow_nil?: false)
      after_commit({AgentConsole, :publish_delete})

      run(fn input, _context ->
        input.arguments.uid |> AgentConsole.delete_in_tx() |> Ankole.Errors.wrap()
      end)
    end

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
    end

    update :profile_in_tx do
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

    update :options_in_tx do
      accept([:options])
    end
  end

  @type t :: %__MODULE__{}
end
