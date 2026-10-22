defmodule Ankole.AgentWorkers.WorkerEnv.EnvVar do
  @moduledoc "One durable operator-defined shell variable under its natural scope and name."

  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.AgentWorkers.WorkerEnv.Domain,
    tenant_in_primary_key: true

  postgres do
    table("agent_computer_worker_envs")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(scope_name: "agent_computer_worker_envs_scope_name_unique")

    check_constraints do
      check_constraint(:scope, "agent_computer_worker_envs_scope_check")
      check_constraint(:name, "agent_computer_worker_envs_name_check")
    end
  end

  attributes do
    attribute(:scope, :string,
      primary_key?: true,
      allow_nil?: false,
      public?: true,
      constraints: [trim?: false]
    )

    attribute(:name, :string,
      primary_key?: true,
      allow_nil?: false,
      public?: true,
      constraints: [trim?: false, match: ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/]
    )

    attribute(:secret, :boolean, allow_nil?: false, public?: true)

    attribute(:value, :string,
      allow_nil?: false,
      sensitive?: true,
      constraints: [trim?: false, match: ~r/\S/]
    )

    attribute(:description, :string, public?: true, constraints: [trim?: false])
    create_timestamp(:inserted_at, type: :utc_datetime)
    update_timestamp(:updated_at, type: :utc_datetime)
  end

  identities do
    identity(:scope_name, [:scope, :name])
  end

  actions do
    defaults([:read])

    create :put do
      accept([:scope, :name])
      argument(:input, :map, allow_nil?: false)
      transaction?(false)
      upsert?(true)
      upsert_identity(:scope_name)
      upsert_fields([:secret, :value, :description, :updated_at])
      validate(Ankole.AppConfigure.Scope)
      change(Ankole.AgentWorkers.WorkerEnv.Changes.PrepareValue, only_when_valid?: true)
    end

    destroy :remove do
      transaction?(false)
      require_atomic?(true)
    end
  end

  @type t :: %__MODULE__{}
end
