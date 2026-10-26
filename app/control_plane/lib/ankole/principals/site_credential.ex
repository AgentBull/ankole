defmodule Ankole.Principals.SiteCredential do
  @moduledoc "A verified site credential bound to one Pod member."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.Principals,
    extensions: [Ankole.Authn, Ankole.Authn.SiteCredentialResource]

  authn do
    strategies do
      otp(:email_otp, sender: Ankole.Authn.Mailer)
    end
  end

  @fields [:principal_uid, :kind, :provider, :identifier, :verified_email, :metadata]

  postgres do
    table("principal_site_credentials")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(subject: "principal_site_credentials_provider_identifier_uidx")

    unique_index_names([
      {[:provider, :identifier], "principal_site_credentials_provider_identifier_uidx"},
      {[:principal_uid, :provider], "principal_site_credentials_principal_provider_uidx"}
    ])

    foreign_key_names([{:principal_uid, "principal_site_credentials_human_fkey"}])
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:principal_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false)
    attribute(:kind, :atom, allow_nil?: false, constraints: [one_of: [:otp, :oidc, :webauthn]])
    attribute(:provider, :string, allow_nil?: false)
    attribute(:identifier, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:verified_email, :string)
    attribute(:metadata, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{})
    timestamps(type: :utc_datetime_usec)
  end

  identities do
    identity(:subject, [:provider, :identifier])
  end

  actions do
    defaults([:read])

    read :read_across_tenants do
      multitenancy(:allow_global)
    end

    create :bind_in_tx do
      accept(@fields)
    end

    destroy(:unbind_in_tx)
  end

  @type t :: %__MODULE__{}
end
