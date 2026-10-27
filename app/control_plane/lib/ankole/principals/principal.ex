defmodule Ankole.Principals.Principal do
  @moduledoc false
  use Ankole.Ash.Resource,
    authorizers: [Ankole.AuthZ.Authorizer],
    tenancy: :tenant,
    domain: Ankole.Principals,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource, Ankole.Authn]

  authn do
    add_ons do
      add_on(:offboarding_release, Ankole.Authn.AddOns.OffboardingRelease)
      add_on(:site_credential_binding, Ankole.Authn.AddOns.SiteCredentialBinding)
      add_on(:pod_invitation, Ankole.Authn.AddOns.PodInvitation)
    end
  end

  authz do
    scope(:site_console)
    resolve_param(:uid, :principal_key)
    allow(:console_list, resource: "site_console:principals", action: "read")
    allow(:read, resource: "site_console:principal:{uid}", action: "read")
    allow(:create_member, resource: "site_console:principals", action: "update")
    allow(:update_human, resource: "site_console:principal:{uid}", action: "update")
    allow(:change_human_membership, resource: "site_console:principal:{uid}", action: "update")
  end

  json_api do
    type("principal")
    derive_filter?(false)
    derive_sort?(false)

    default_fields([
      :type,
      :status,
      :membership,
      :display_name,
      :avatar_url,
      :email,
      :handle,
      :has_external_identity
    ])
  end

  postgres do
    table("principals")
    repo(Ankole.Repo)
    migrate?(false)
    unique_index_names([{[:type], "principals_one_system_per_tenant_index"}])

    check_constraints do
      check_constraint(:membership, "principals_membership_shape")
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

    attribute(:membership, :atom,
      public?: true,
      constraints: [one_of: [:member, :guest]]
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

    has_many :access_events, Ankole.Principals.AccessEvent do
      source_attribute(:uid)
      destination_attribute(:principal_uid)
    end
  end

  aggregates do
    exists(:has_external_identity, :external_identities, public?: true)
  end

  calculations do
    calculate(:email, :string, expr(human_user.email), public?: true)
    calculate(:handle, :string, expr(agent.handle), public?: true)
  end

  actions do
    defaults([:read])

    read :console_list do
      argument(:include_disabled, :boolean, default: false)
      filter(expr(status == :active or ^arg(:include_disabled) == true))
      prepare(build(sort: [uid: :asc]))
    end

    read :read_across_tenants do
      multitenancy(:allow_global)
    end

    create :create_in_tx do
      accept([:uid, :type, :membership, :display_name, :avatar_url])

      change(set_attribute(:membership, :member),
        where: [attribute_equals(:type, :human), attribute_equals(:membership, nil)]
      )
    end

    update :membership_in_tx do
      accept([:membership])
      validate(attribute_equals(:type, :human))
      validate(attribute_does_not_equal(:membership, nil))

      change(fn changeset, _context ->
        if Ash.Changeset.changing_attribute?(changeset, :membership) do
          Ash.Changeset.force_change_attribute(
            changeset,
            :access_version,
            changeset.data.access_version + 1
          )
        else
          changeset
        end
      end)
    end

    update :profile_in_tx do
      accept([:display_name, :avatar_url])
    end

    update :enable_in_tx do
      accept([])
      change(set_attribute(:status, :active))
    end

    update :disable_in_tx do
      accept([])
      change(set_attribute(:status, :disabled))
    end

    update :revoke_human_in_tx do
      accept([])
      validate(attribute_equals(:type, :human))
      change(Ankole.Principals.Changes.RevokeHuman)
    end

    destroy(:delete_in_tx)

    action :update_human, :struct do
      description("Updates the display name or directory email of a Human.")
      constraints(instance_of: __MODULE__)
      argument(:uid, :string, allow_nil?: false)
      argument(:display_name, :string)
      argument(:email, :string)

      run(__MODULE__.Actions)
    end

    action :change_human_membership, :struct do
      description("Changes Human membership and revokes prior access versions.")
      constraints(instance_of: __MODULE__)
      argument(:uid, :string, allow_nil?: false)
      argument(:membership, :atom, allow_nil?: false, constraints: [one_of: [:member, :guest]])
      run(__MODULE__.Actions)
    end

    action :create_member, :map do
      description("Creates a Pod member profile. Personal login requires email verification.")

      constraints(
        fields: [
          uid: [type: Ankole.Ash.Types.PrincipalKey, allow_nil?: false],
          email: [type: :string]
        ]
      )

      argument(:email, :string, allow_nil?: false, constraints: [min_length: 1])

      argument(:membership, :atom,
        default: :member,
        allow_nil?: false,
        constraints: [one_of: [:member, :guest]]
      )

      argument(:display_name, :string)
      run(__MODULE__.Actions)
    end
  end

  @type t :: %__MODULE__{}
end
