defmodule Ankole.Principals.ExternalIdentity do
  @moduledoc false
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.Principals,
    extensions: [AshJsonApi.Resource, Ankole.Authn, Ankole.Authn.SubjectIdentity]

  authn do
    strategies do
      oidc(:enterprise)
    end
  end

  # The Console API gives a bound identity without its provider metadata.
  json_api do
    type("external_identity")
    derive_filter?(false)
    derive_sort?(false)
    default_fields([:principal_uid, :provider, :external_id])
  end

  postgres do
    table("principal_external_identities")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(subject: "principal_external_identities_provider_identity_index")
    foreign_key_names([{:principal_uid, "principal_external_identities_principal_uid_fkey"}])

    unique_index_names([
      {[:provider, :external_id], "principal_external_identities_provider_identity_index"}
    ])

    check_constraints do
      check_constraint(:provider, "principal_external_identities_provider_format")
      check_constraint(:metadata, "principal_external_identities_metadata_object")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      public?: true,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:principal_uid, Ankole.Ash.Types.PrincipalKey, public?: true, allow_nil?: false)
    attribute(:provider, :string, public?: true, allow_nil?: false)
    attribute(:external_id, :string, public?: true, allow_nil?: false)
    attribute(:metadata, Ankole.Ash.Types.JSONMap, public?: true, allow_nil?: false, default: %{})
    timestamps(type: :utc_datetime_usec)
  end

  identities do
    identity(:subject, [:provider, :external_id])
  end

  relationships do
    belongs_to :principal, Ankole.Principals.Principal do
      source_attribute(:principal_uid)
      destination_attribute(:uid)
      define_attribute?(false)
    end
  end

  validations do
    validate(match(:provider, ~r/\A[a-z][a-z0-9_-]*\z/))
  end

  actions do
    defaults([:read])

    read :read_across_tenants do
      multitenancy(:allow_global)
    end

    create :bind_in_tx do
      accept([:principal_uid, :provider, :external_id, :metadata])
    end

    update :observe_in_tx do
      accept([:metadata])
    end

    destroy(:unbind_in_tx)
  end

  @type t :: %__MODULE__{}
end
