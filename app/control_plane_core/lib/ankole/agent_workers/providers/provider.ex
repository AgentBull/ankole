defmodule Ankole.AgentWorkers.Providers.Provider do
  @moduledoc "A durable Worker pool: one immutable kind and location, YAML and encrypted credentials."

  use Ankole.Ash.Resource,
    tenancy: :site,
    domain: Ankole.AgentWorkers.Domain

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

  validations do
    validate(match(:provider_id, ~r/\A[a-z]([a-z0-9-]{0,61}[a-z0-9])?\z/),
      message: "has invalid format"
    )

    validate(match(:display_name, ~r/\S/), message: "can't be blank")
    validate(match(:config, ~r/\S/), message: "can't be blank")
  end

  actions do
    defaults([:read])

    create :create do
      accept([:provider_id, :kind, :display_name, :config, :is_default])
      argument(:credential_input, :map, allow_nil?: false, default: %{}, sensitive?: true)
      transaction?(false)
      validate(present([:provider_id, :kind, :display_name, :config, :is_default]))
      change(Ankole.AgentWorkers.Providers.Changes.PrepareConfiguration, only_when_valid?: true)
    end

    in_tx_update :configure do
      accept([:provider_id, :kind, :display_name, :config, :is_default])
      argument(:credential_input, :map, allow_nil?: false, default: %{}, sensitive?: true)
      validate(Ankole.AgentWorkers.Providers.ImmutableIdentity)
      change(Ankole.AgentWorkers.Providers.Changes.PrepareConfiguration, only_when_valid?: true)
    end

    atomic_in_tx_update :unset_default do
      accept([])
      skip_global_validations?(true)
      change(set_attribute(:is_default, false))
    end

    destroy :remove do
      transaction?(false)
      require_atomic?(false)
      atomic_upgrade?(false)
    end
  end

  @type t :: %__MODULE__{}
end
