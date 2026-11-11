defmodule Ankole.AgentWorkers.RunnerBinding do
  @moduledoc "The Agent Computer and persistent Home of one Agent on one registered device."

  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.AgentWorkers

  @type t :: %__MODULE__{}

  postgres do
    table("runner_bindings")
    repo(Ankole.Repo)
    migrate?(false)
  end

  attributes do
    attribute(:runner_id, Ankole.Ash.Types.UUIDv7, primary_key?: true, allow_nil?: false)
    attribute(:agent_uid, Ankole.Ash.Types.PrincipalKey, primary_key?: true, allow_nil?: false)
    attribute(:generation, :string, allow_nil?: false)
    attribute(:token_digest, :binary, allow_nil?: false, sensitive?: true)
    attribute(:token_ciphertext, :binary, allow_nil?: false, sensitive?: true)
    attribute(:protocol_version, :integer, allow_nil?: false)
    attribute(:image, :string, allow_nil?: false)
    attribute(:instance_settings, Ankole.Ash.Types.JSONMap, allow_nil?: false)

    attribute(:state, :atom,
      allow_nil?: false,
      default: :starting,
      constraints: [one_of: [:starting, :ready, :stale, :draining]]
    )

    attribute(:transport_route, :string)
    attribute(:incarnation_id, :string)
    attribute(:last_worker_heartbeat_at, :utc_datetime_usec)
    attribute(:capacity, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{})
    attribute(:load, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{})
  end

  actions do
    defaults([:read])

    read :by_credential do
      multitenancy(:allow_global)
    end

    create :register do
      accept([
        :runner_id,
        :agent_uid,
        :generation,
        :token_digest,
        :token_ciphertext,
        :protocol_version,
        :image,
        :instance_settings
      ])
    end

    update :connection do
      require_atomic?(false)

      accept([
        :state,
        :transport_route,
        :incarnation_id,
        :last_worker_heartbeat_at,
        :capacity,
        :load
      ])
    end

    update :replace_generation do
      require_atomic?(false)

      accept([
        :generation,
        :token_digest,
        :token_ciphertext,
        :protocol_version,
        :image,
        :instance_settings
      ])

      change(set_attribute(:state, :starting))
      change(set_attribute(:transport_route, nil))
      change(set_attribute(:incarnation_id, nil))
      change(set_attribute(:last_worker_heartbeat_at, nil))
      change(set_attribute(:capacity, %{}))
      change(set_attribute(:load, %{}))
    end
  end
end
