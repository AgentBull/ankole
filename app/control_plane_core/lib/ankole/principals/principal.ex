defmodule Ankole.Principals.Principal do
  @moduledoc false
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Principals.Domain

  postgres do
    table("principals")
    repo(Ankole.Repo)
    migrate?(false)
    unique_index_names([{[:type], "principals_one_system_per_tenant_index"}])

    check_constraints do
      check_constraint(:uid, "principals_uid_present")
      check_constraint(:uid, "principals_uid_lowercase")
      check_constraint(:display_name, "principals_agent_display_name_present")
      check_constraint(:access_version, "principals_access_version_positive")
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
      constraints: [one_of: [:human, :agent, :system]]
    )

    attribute(:status, :atom,
      public?: true,
      allow_nil?: false,
      default: :active,
      constraints: [one_of: [:active, :disabled]]
    )

    attribute(:access_version, :integer,
      public?: true,
      allow_nil?: false,
      default: 1,
      constraints: [min: 1]
    )

    attribute(:access_revoked_at, :utc_datetime_usec, public?: true)
    attribute(:display_name, :string, public?: true)
    attribute(:avatar_url, :string, public?: true)
    timestamps(type: :utc_datetime_usec)
  end

  relationships do
    has_one :human_user, Ankole.Principals.HumanUser do
      source_attribute(:uid)
      destination_attribute(:principal_uid)
    end

    has_one :agent, Ankole.Principals.Agent do
      source_attribute(:uid)
      destination_attribute(:uid)
    end

    has_many :external_identities, Ankole.Principals.ExternalIdentity do
      source_attribute(:uid)
      destination_attribute(:principal_uid)
    end
  end

  actions do
    defaults([:read])

    create :create_in_tx do
      accept([:uid, :type, :display_name, :avatar_url])
      transaction?(false)
      change(Ankole.Ash.RequireTransaction)
    end

    in_tx_update :profile_in_tx do
      accept([:display_name, :avatar_url])
    end

    in_tx_update :enable_in_tx do
      accept([])
      change(set_attribute(:status, :active))
    end

    in_tx_update :disable_in_tx do
      accept([])
      change(set_attribute(:status, :disabled))
    end

    in_tx_update :revoke_human_in_tx do
      accept([])
      validate(attribute_equals(:type, :human))
      change(Ankole.Principals.Changes.RevokeHuman)
    end

    destroy :delete_in_tx do
      transaction?(false)
      require_atomic?(false)
      atomic_upgrade?(false)
      change(Ankole.Ash.RequireTransaction)
    end
  end

  @type t :: %__MODULE__{}
end
