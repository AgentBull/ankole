defmodule Ankole.Principals.MappingRequest do
  @moduledoc false
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Principals.Domain

  postgres do
    table("identity_mapping_requests")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(subject: "identity_mapping_requests_subject_index")
    unique_index_names([{[:provider, :external_id], "identity_mapping_requests_subject_index"}])

    check_constraints do
      check_constraint(:provider, "identity_mapping_requests_provider_format")
      check_constraint(:metadata, "identity_mapping_requests_metadata_object")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      public?: true,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:provider, :string, public?: true, allow_nil?: false)
    attribute(:external_id, :string, public?: true, allow_nil?: false)
    attribute(:display_name, :string, public?: true)
    attribute(:email, :string, public?: true)
    attribute(:mobile, :string, public?: true)
    attribute(:metadata, Ankole.Ash.Types.JSONMap, public?: true, allow_nil?: false, default: %{})
    timestamps(type: :utc_datetime_usec)
  end

  identities do
    identity(:subject, [:provider, :external_id])
  end

  validations do
    validate(match(:provider, ~r/\A[a-z][a-z0-9_-]*\z/))
  end

  actions do
    defaults([:read])

    create :observe_in_tx do
      accept([:provider, :external_id, :display_name, :email, :mobile, :metadata])
      transaction?(false)
      change(Ankole.Ash.RequireTransaction)
      upsert?(true)
      upsert_identity(:subject)
      upsert_fields([:display_name, :email, :mobile, :metadata, :updated_at])
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
