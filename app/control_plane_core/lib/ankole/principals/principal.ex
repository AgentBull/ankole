defmodule Ankole.Principals.Principal do
  @moduledoc false
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.Principals,
    extensions: [AshJsonApi.Resource]

  json_api do
    type("principal")
    derive_filter?(false)
    derive_sort?(false)

    default_fields([
      :type,
      :status,
      :display_name,
      :avatar_url,
      :email,
      :handle,
      :has_external_identity,
      :local_credential_status
    ])
  end

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

    has_one :local_credential, Ankole.Principals.LocalCredential do
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

    calculate(
      :local_credential_status,
      :atom,
      expr(
        if is_nil(local_credential.principal_uid) do
          nil
        else
          if local_credential.must_change_password, do: :must_change, else: :active
        end
      ),
      constraints: [one_of: [:must_change, :active]],
      public?: true
    )
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
      accept([:uid, :type, :display_name, :avatar_url])
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

    action :create_human, :map do
      argument(:attrs, :map, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Errors.wrap(
          Ankole.Principals.create_human_in_tx(Ankole.Repo, input.arguments.attrs)
        )
      end)
    end

    action :create_agent, :map do
      argument(:attrs, :map, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Errors.wrap(
          Ankole.Principals.create_agent_in_tx(Ankole.Repo, input.arguments.attrs)
        )
      end)
    end

    action :enable_agent, :term do
      argument(:uid, :term, allow_nil?: false)
      after_commit({Ankole.Principals, :publish_agent_changes})

      run(fn input, _context ->
        Ankole.Errors.wrap(Ankole.Principals.enable_agent_in_tx(Ankole.Repo, input.arguments.uid))
      end)
    end

    action :delete_agent, :term do
      argument(:uid, :term, allow_nil?: false)
      after_commit({Ankole.Principals, :publish_agent_deletion})

      run(fn input, _context ->
        Ankole.Errors.wrap(Ankole.Principals.delete_agent_in_tx(Ankole.Repo, input.arguments.uid))
      end)
    end

    action :upsert_platform_subject_human, :map do
      argument(:attrs, :map, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Repo
        |> Ankole.Principals.upsert_platform_subject_human_in_tx(input.arguments.attrs)
        |> Ankole.Errors.wrap()
      end)
    end

    action :update_human, :struct do
      description("Updates the display name or the email of a Human with local sign-in.")
      constraints(instance_of: __MODULE__)
      argument(:uid, :string, allow_nil?: false)
      argument(:display_name, :string)
      argument(:email, :string)

      run(fn input, _context ->
        Ankole.Principals.update_human_in_tx(Ankole.Repo, input.arguments)
        |> Ankole.Errors.not_found([:not_found, :principal_not_found], __MODULE__)
        |> Ankole.Errors.wrap(&Ankole.Principals.describe_refusal/1)
      end)
    end

    action :create_local_user, :struct do
      description("Creates a Human with an email and a generated one-time local password.")
      constraints(instance_of: __MODULE__)
      argument(:email, :string, allow_nil?: false)
      argument(:display_name, :string)

      argument(:must_change_password, :boolean,
        default: true,
        description: "Omitted or null means true."
      )

      argument(:initial_password, :string, public?: false, sensitive?: true)
      argument(:password_hash, :string, public?: false, sensitive?: true)
      prepare(Ankole.Principals.Changes.InitialPassword)

      run(fn input, _context ->
        Ankole.Principals.create_local_user_in_tx(Ankole.Repo, input.arguments)
        |> Ankole.Errors.wrap(&Ankole.Principals.describe_refusal/1)
      end)
    end

    action :update_agent, :map do
      argument(:uid, :term, allow_nil?: false)
      argument(:attrs, :map, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Principals.update_agent_in_tx(
          Ankole.Repo,
          input.arguments.uid,
          input.arguments.attrs
        )
        |> Ankole.Errors.wrap()
      end)
    end

    action :recover_admin, :struct do
      constraints(instance_of: __MODULE__)
      argument(:uid, :term, allow_nil?: false)
      argument(:operator, :term, allow_nil?: false)
      argument(:reason, :term)

      run(fn input, _context ->
        Ankole.Principals.HumanAccess.recover_admin_in_tx(
          Ankole.Repo,
          input.arguments.uid,
          input.arguments.operator,
          input.arguments.reason
        )
        |> Ankole.Errors.wrap()
      end)
    end

    action :restrict, :struct do
      constraints(instance_of: __MODULE__)
      argument(:uid, :term, allow_nil?: false)
      argument(:attrs, :map, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Principals.HumanAccess.restrict_in_tx(
          Ankole.Repo,
          input.arguments.uid,
          input.arguments.attrs
        )
        |> Ankole.Errors.wrap()
      end)
    end

    action :verify_provider_recovery, :term do
      argument(:uid, :term, allow_nil?: false)
      argument(:provider_id, :term, allow_nil?: false)
      argument(:operation_id, :term, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Principals.HumanAccess.verify_provider_recovery_in_tx(
          Ankole.Repo,
          input.arguments.uid,
          input.arguments.provider_id,
          input.arguments.operation_id
        )
        |> Ankole.Errors.wrap()
      end)
    end

    action :clear_restriction, :term do
      argument(:uid, :term, allow_nil?: false)
      argument(:restriction_id, :term, allow_nil?: false)
      argument(:actor, :term)
      argument(:reason, :term)
      argument(:operation_id, :term, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Principals.HumanAccess.clear_restriction_in_tx(
          Ankole.Repo,
          input.arguments.uid,
          input.arguments.restriction_id,
          input.arguments.actor,
          input.arguments.reason,
          input.arguments.operation_id
        )
        |> Ankole.Errors.wrap()
      end)
    end

    action :restore, :struct do
      constraints(instance_of: __MODULE__)
      argument(:uid, :term, allow_nil?: false)
      argument(:review_fingerprint, :term)
      argument(:actor, :term)
      argument(:reason, :term)
      argument(:operation_id, :term, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Principals.HumanAccess.restore_in_tx(
          Ankole.Repo,
          input.arguments.uid,
          input.arguments.review_fingerprint,
          input.arguments.actor,
          input.arguments.reason,
          input.arguments.operation_id
        )
        |> Ankole.Errors.wrap()
      end)
    end

    action :classify_work, :map do
      argument(:kind, :term, allow_nil?: false)
      argument(:id, :term, allow_nil?: false)
      argument(:human_uid, :term)
      argument(:actor, :term, allow_nil?: false)
      argument(:reason, :term, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Principals.WorkAccess.classify_in_tx(
          Ankole.Repo,
          input.arguments.kind,
          input.arguments.id,
          input.arguments.human_uid,
          input.arguments.actor,
          input.arguments.reason
        )
        |> Ankole.Errors.wrap()
      end)
    end

    action :cleanup_work, :map do
      argument(:uid, :term, allow_nil?: false)
      argument(:version, :integer, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Principals.WorkCleanup.cleanup_in_tx(
          Ankole.Repo,
          input.arguments.uid,
          input.arguments.version
        )
        |> Ankole.Errors.wrap()
      end)
    end
  end

  @type t :: %__MODULE__{}
end
