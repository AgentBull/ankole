defmodule Ankole.Principals.Agent do
  @moduledoc """
  The agent subtype of a Principal.

  The Console reads an Agent with the status, the name, and the avatar of its
  Principal and the provider of its Worker. A Console write runs one generic
  action that changes the Principal and the Agent rows in one transaction.
  """
  use Ankole.Ash.Resource,
    authorizers: [Ankole.AuthZ.Authorizer],
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.Principals,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  authz do
    scope(:site_console)
    resolve_param(:uid, :principal_key)
    allow(:console_list, resource: "site_console:agents", action: "read")
    allow(:read, resource: "site_console:agent:{uid}", action: "read")
    allow(:console_create, resource: "site_console:agents", action: "update")
    allow(:console_update, resource: "site_console:agent:{uid}", action: "update")
    allow(:console_delete, resource: "site_console:agent:{uid}", action: "delete")
    allow(:console_enable, resource: "site_console:agent:{uid}", action: "update")
    allow(:console_rename, resource: "site_console:agent:{uid}", action: "update")
  end

  alias Ankole.Principals.AgentConsole
  @uid_format ~r/\A[a-z0-9][a-z0-9._@+-]{0,95}\z/

  def valid_uid?(uid), do: is_binary(uid) and Regex.match?(@uid_format, uid)

  json_api do
    primary_key do
      keys([:uid])
    end

    type("agent")
    derive_filter?(false)
    derive_sort?(false)

    # The primary key names the record in the result of a generic action.
    default_fields([
      :uid,
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

    unique_index_names([{[:owner_principal_uid], "agents_personal_assistant_owner_index"}])

    foreign_key_names([
      {:uid, "agents_uid_fkey"},
      {:owner_principal_uid, "agents_owner_principal_uid_fkey"}
    ])

    check_constraints do
      check_constraint(:uid, "agents_uid_agent_home_safe")
      check_constraint(:group_memory_disclosure_mode, "personal_assistant_strict_memory")
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

    attribute(:type, :atom,
      public?: true,
      allow_nil?: false,
      default: :ai_colleague,
      constraints: [one_of: [:ai_colleague, :personal_assistant]]
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
      allow_nil?: false,
      constraints: [one_of: [:active, :disabled]]
    )

    calculate(:display_name, :string, expr(principal.display_name), public?: true)
    calculate(:avatar_url, :string, expr(principal.avatar_url), public?: true)

    calculate(:worker_provider_id, :string, Ankole.Principals.Agent.WorkerProviderID,
      public?: true
    )
  end

  validations do
    validate(match(:uid, @uid_format))
  end

  actions do
    defaults([:read])

    action :console_rename, :map do
      constraints(
        fields: [uid: [type: :string, allow_nil?: false], base_repair_error: [type: :string]]
      )

      argument(:uid, :string, allow_nil?: false)
      argument(:new_uid, :string, allow_nil?: false)
      transaction?(false)
      run(__MODULE__.Actions)
    end

    read :console_list do
      filter(expr(type == :ai_colleague))
      prepare(build(sort: [inserted_at: :asc]))
    end

    action :console_create, :struct do
      constraints(instance_of: __MODULE__)
      argument(:uid, :string, allow_nil?: false)
      argument(:display_name, :string, allow_nil?: false)
      argument(:avatar_url, :string)
      argument(:role, :string, allow_nil?: false)
      argument(:options, Ankole.Ash.Types.JSONMap)
      argument(:owner_principal_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false)

      argument(:group_memory_disclosure_mode, :atom, constraints: [one_of: [:strict, :relaxed]])

      argument(:worker_provider_id, :string)

      run(__MODULE__.Actions)
    end

    action :console_update, :struct do
      constraints(instance_of: __MODULE__)
      argument(:uid, :string, allow_nil?: false)
      argument(:display_name, :string)
      argument(:avatar_url, :string)
      argument(:role, :string)
      argument(:options, Ankole.Ash.Types.JSONMap)
      argument(:owner_principal_uid, Ankole.Ash.Types.PrincipalKey)

      argument(:group_memory_disclosure_mode, :atom, constraints: [one_of: [:strict, :relaxed]])

      run(__MODULE__.Actions)
    end

    action :console_enable, :struct do
      constraints(instance_of: __MODULE__)
      argument(:uid, :string, allow_nil?: false)
      after_commit({AgentConsole, :publish_enable})

      run(__MODULE__.Actions)
    end

    action :console_delete, :struct do
      constraints(instance_of: __MODULE__)
      argument(:uid, :string, allow_nil?: false)
      after_commit({AgentConsole, :publish_delete})

      run(__MODULE__.Actions)
    end

    create :create_in_tx do
      accept([
        :uid,
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
