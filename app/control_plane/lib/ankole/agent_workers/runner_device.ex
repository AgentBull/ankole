defmodule Ankole.AgentWorkers.RunnerDevice do
  @moduledoc "A member's registered machine and its enrollment credential."

  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.AgentWorkers

  postgres do
    table("runner_devices")
    repo(Ankole.Repo)
    migrate?(false)
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7, primary_key?: true, allow_nil?: false)
    attribute(:owner_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false)
    attribute(:owner_access_version, :integer, allow_nil?: false)
    attribute(:name, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 80])
    attribute(:pairing_digest, :binary, sensitive?: true)
    attribute(:pairing_expires_at, :utc_datetime_usec)
    attribute(:token_digest, :binary, sensitive?: true)
    attribute(:revoked_at, :utc_datetime_usec)
  end

  actions do
    defaults([:read])

    read :by_credential do
      multitenancy(:allow_global)
    end

    create :register do
      accept([
        :id,
        :owner_uid,
        :owner_access_version,
        :name,
        :pairing_digest,
        :pairing_expires_at
      ])
    end

    update :credentials do
      require_atomic?(false)
      accept([:pairing_digest, :pairing_expires_at, :token_digest, :revoked_at])
    end
  end
end
