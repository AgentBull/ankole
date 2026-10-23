defmodule Ankole.AgentWorkers.Providers.Provider do
  @moduledoc "A durable Worker pool: one immutable kind and location, YAML and encrypted credentials."

  use Ankole.Ash.Resource,
    tenancy: :site,
    domain: Ankole.AgentWorkers.Providers,
    extensions: [AshJsonApi.Resource]

  alias Ankole.AgentWorkers.Providers
  alias Ankole.AgentWorkers.Providers.Projection

  json_api do
    type("worker_provider")
    derive_filter?(false)
    derive_sort?(false)

    default_fields([
      :provider_id,
      :kind,
      :display_name,
      :config,
      :is_default,
      :agent_count,
      :selectable,
      :stored_credentials
    ])
  end

  postgres do
    table("worker_providers")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(provider_id: "worker_providers_provider_id_index")
    unique_index_names([{[:is_default], "worker_providers_one_default"}])
    foreign_key_names([{:provider_id, "agent_workers_provider_id_fkey"}])

    check_constraints do
      check_constraint(:provider_id, "worker_providers_id_format")
      check_constraint(:credentials, "worker_providers_credentials_object")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0,
      public?: true
    )

    attribute(:provider_id, :string,
      allow_nil?: false,
      public?: true,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:kind, :string, allow_nil?: false, public?: true, constraints: [trim?: false])

    attribute(:display_name, :string,
      allow_nil?: false,
      public?: true,
      constraints: [trim?: false]
    )

    attribute(:config, :string, allow_nil?: false, public?: true, constraints: [trim?: false])

    attribute(:credentials, Ankole.Ash.Types.JSONMap,
      allow_nil?: false,
      writable?: false,
      sensitive?: true,
      default: %{}
    )

    attribute(:is_default, :boolean, allow_nil?: false, default: false, public?: true)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:provider_id, [:provider_id])
  end

  # The operator projection. A credential value never leaves the row: only the
  # names of the stored credentials do.
  calculations do
    calculate(:agent_count, :integer, {Projection, field: :agent_count},
      allow_nil?: false,
      public?: true
    )

    calculate(:selectable, :boolean, {Projection, field: :selectable},
      allow_nil?: false,
      public?: true
    )

    calculate(:stored_credentials, {:array, :string}, {Projection, field: :stored_credentials},
      allow_nil?: false,
      public?: true
    )
  end

  validations do
    validate(match(:provider_id, ~r/\A[a-z]([a-z0-9-]{0,61}[a-z0-9])?\z/),
      message: "has invalid format"
    )

    validate(match(:display_name, ~r/\S/), message: "can't be blank")
    validate(match(:config, ~r/\S/), message: "can't be blank")
  end

  actions do
    defaults([:read])

    read :list do
      prepare(build(sort: [provider_id: :asc]))
    end

    create :create do
      accept([:provider_id, :kind, :display_name, :config, :is_default])
      argument(:credential_input, :map, allow_nil?: false, default: %{}, sensitive?: true)
      validate(present([:provider_id, :kind, :display_name, :config, :is_default]))
      change(Ankole.AgentWorkers.Providers.Changes.PrepareConfiguration, only_when_valid?: true)
    end

    update :configure do
      accept([:provider_id, :kind, :display_name, :config, :is_default])
      argument(:credential_input, :map, allow_nil?: false, default: %{}, sensitive?: true)
      validate(Ankole.AgentWorkers.Providers.ImmutableIdentity)
      change(Ankole.AgentWorkers.Providers.Changes.PrepareConfiguration, only_when_valid?: true)
    end

    update :unset_default do
      require_atomic?(true)
      accept([])
      skip_global_validations?(true)
      change(set_attribute(:is_default, false))
    end

    destroy(:remove)

    # The registry operations own their transaction and take the registry
    # lock before they read or change a provider.

    # The arguments keep the raw values: the `create` and `configure`
    # actions validate them. An omitted argument keeps the stored value.
    action :add, :struct do
      constraints(instance_of: __MODULE__)
      argument(:provider_id, :string, constraints: [trim?: false, allow_empty?: true])
      argument(:kind, :string, constraints: [trim?: false, allow_empty?: true])
      argument(:display_name, :string, constraints: [trim?: false, allow_empty?: true])
      argument(:config, :string, constraints: [trim?: false, allow_empty?: true])
      argument(:is_default, :boolean)
      argument(:credentials, :map, sensitive?: true)

      run(__MODULE__.Actions)
    end

    action :configure_provider, :struct do
      constraints(instance_of: __MODULE__)
      argument(:provider_id, :string, allow_nil?: false, constraints: [trim?: false])
      argument(:kind, :string, constraints: [trim?: false, allow_empty?: true])
      argument(:display_name, :string, constraints: [trim?: false, allow_empty?: true])
      argument(:config, :string, constraints: [trim?: false, allow_empty?: true])
      argument(:is_default, :boolean)
      argument(:credentials, :map, sensitive?: true)
      after_commit({Providers, :reconcile_workers})

      run(__MODULE__.Actions)
    end

    action :delete_provider, :struct do
      constraints(instance_of: __MODULE__)
      argument(:provider_id, :string, allow_nil?: false, constraints: [trim?: false])

      run(__MODULE__.Actions)
    end

    action :import_seed do
      argument(:path, :string, constraints: [trim?: false])
      run(__MODULE__.Actions)
    end
  end

  @type t :: %__MODULE__{}
end
