defmodule Ankole.BrowserSessions.Authentication do
  @moduledoc false
  use Ankole.Ash.Resource, tenancy: :site, domain: Ankole.BrowserSessions

  @proof_fields [
    :revision,
    :auth_time,
    :external_id,
    :console_authenticated,
    :csrf_token,
    :expires_at
  ]

  postgres do
    table("browser_authentications")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(subject: "browser_authentications_subject_index")

    foreign_key_names([
      {:browser_id, "browser_authentications_browser_id_fkey"},
      {:tenant_id, "browser_authentications_tenant_id_fkey"}
    ])

    unique_index_names([
      {[:browser_id, :provider_id, :subject_id, :purpose, :tenant_id],
       "browser_authentications_subject_index"}
    ])

    check_constraints do
      check_constraint(:tenant_id, "browser_authentications_subject_scope")
      check_constraint(:revision, "browser_authentications_revision_positive")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      public?: true,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:browser_id, Ankole.Ash.Types.UUIDv7, public?: true, allow_nil?: false)
    attribute(:tenant_id, Ankole.Ash.Types.UUIDv7, public?: true)

    attribute(:provider_id, :string,
      public?: true,
      allow_nil?: false,
      constraints: [trim?: false]
    )

    attribute(:subject_id, :string, public?: true, allow_nil?: false, constraints: [trim?: false])
    attribute(:external_id, :string, public?: true, constraints: [trim?: false])

    attribute(:purpose, :atom,
      public?: true,
      allow_nil?: false,
      constraints: [one_of: [:console, :oauth, :pod, :site]]
    )

    attribute(:console_authenticated, :boolean, public?: true, allow_nil?: false, default: false)
    attribute(:revision, :integer, public?: true, allow_nil?: false, constraints: [min: 1])
    attribute(:auth_time, :integer, public?: true)

    attribute(:csrf_token, :string,
      public?: true,
      allow_nil?: false,
      sensitive?: true,
      constraints: [trim?: false]
    )

    attribute(:expires_at, :utc_datetime_usec, public?: true, allow_nil?: false)
    attribute(:revoked_at, :utc_datetime_usec, public?: true)
    timestamps(type: :utc_datetime_usec)
  end

  identities do
    identity(:subject, [:browser_id, :provider_id, :subject_id, :purpose, :tenant_id],
      nils_distinct?: false
    )
  end

  validations do
    validate(Ankole.BrowserSessions.Validations.TargetScope, only_when_valid?: true)
  end

  actions do
    defaults([:read])

    create :create_in_tx do
      accept([:browser_id, :tenant_id, :provider_id, :subject_id, :purpose] ++ @proof_fields)
    end

    update :renew_in_tx do
      accept(@proof_fields)
      change(set_attribute(:revoked_at, nil))
    end

    update :revoke_in_tx do
      accept([:revision])
      change(set_attribute(:revoked_at, &DateTime.utc_now/0))
    end

    action :revoke, :term do
      argument(:browser_ref, :term)
      argument(:authentication_ref, :term)

      run(__MODULE__.Actions)
    end

    action :create_pod_access, :term do
      argument(:authentication_ref, :term)
      argument(:create, :term)

      run(__MODULE__.Actions)
    end

    action :connect_pod_access, :term do
      argument(:authentication_ref, :term)
      argument(:verified_ref, :term)
      argument(:tenant_id, :term)
      argument(:connect, :term)

      run(__MODULE__.Actions)
    end
  end

  @type t :: %__MODULE__{}
end
