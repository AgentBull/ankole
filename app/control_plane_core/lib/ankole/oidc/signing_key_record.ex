defmodule Ankole.OIDC.SigningKeyRecord do
  @moduledoc false
  use Ankole.Ash.Resource, tenancy: :site, domain: Ankole.OIDC

  postgres do
    table("oidc_signing_keys")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(kid: "oidc_signing_keys_kid_index")

    check_constraints do
      check_constraint(:id, "oidc_signing_keys_primary_only")
    end
  end

  attributes do
    attribute(:id, :string,
      public?: true,
      primary_key?: true,
      allow_nil?: false,
      constraints: [trim?: false]
    )

    attribute(:kid, :string, public?: true, allow_nil?: false, constraints: [trim?: false])
    attribute(:public_jwk, Ankole.Ash.Types.JSONMap, public?: true, allow_nil?: false)

    attribute(:private_key_ciphertext, :string,
      public?: true,
      sensitive?: true,
      allow_nil?: false,
      constraints: [trim?: false]
    )

    timestamps(type: :utc_datetime_usec)
  end

  identities do
    identity(:kid, [:kid])
  end

  actions do
    defaults([:read])

    create_if_absent :initialize_in_tx, upsert_fields: [:id] do
      accept([:id, :kid, :public_jwk, :private_key_ciphertext])
      validate(attribute_equals(:id, "primary"))
    end
  end

  @type t :: %__MODULE__{}
end
