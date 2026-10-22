defmodule Ankole.OIDC.RefreshToken do
  @moduledoc false
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.OIDC.Domain

  postgres do
    table("oidc_refresh_tokens")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(generation: "oidc_refresh_tokens_family_id_generation_index")

    foreign_key_names(
      family_id: "oidc_refresh_tokens_family_id_fkey",
      client_id: "oidc_refresh_tokens_client_id_fkey",
      principal_uid: "oidc_refresh_tokens_principal_uid_fkey",
      session_id: "oidc_refresh_tokens_session_id_fkey"
    )

    check_constraints do
      check_constraint(:generation, "oidc_refresh_tokens_generation")
      check_constraint(:consumed_at, "oidc_refresh_tokens_consumption")
      check_constraint(:successor_retry_until, "oidc_refresh_tokens_consumption_deadline")
      check_constraint(:context, "oidc_refresh_tokens_context")
    end
  end

  attributes do
    attribute(:digest, :string,
      primary_key?: true,
      public?: true,
      allow_nil?: false,
      constraints: [trim?: false]
    )

    attribute(:client_id, Ankole.Ash.Types.UUIDv7, public?: true, allow_nil?: false)
    attribute(:principal_uid, Ankole.Ash.Types.PrincipalKey, public?: true, allow_nil?: false)
    attribute(:session_id, Ankole.Ash.Types.UUIDv7, public?: true, allow_nil?: false)
    attribute(:family_id, :string, public?: true, allow_nil?: false, constraints: [trim?: false])
    attribute(:generation, :integer, public?: true, allow_nil?: false, constraints: [min: 0])
    attribute(:scope, :string, public?: true, allow_nil?: false, constraints: [trim?: false])
    attribute(:context, Ankole.Ash.Types.JSONMap, public?: true, allow_nil?: false)
    attribute(:expires_at, :utc_datetime_usec, public?: true, allow_nil?: false)
    attribute(:consumed_at, :utc_datetime_usec, public?: true)

    attribute(:successor_ciphertext, :string,
      public?: true,
      sensitive?: true,
      constraints: [trim?: false]
    )

    attribute(:successor_retry_until, :utc_datetime_usec, public?: true)
    timestamps(type: :utc_datetime_usec)
  end

  identities do
    identity(:generation, [:family_id, :generation], all_tenants?: true)
  end

  actions do
    defaults([:read])

    create :issue_in_tx do
      accept([
        :digest,
        :client_id,
        :principal_uid,
        :session_id,
        :family_id,
        :generation,
        :scope,
        :context,
        :expires_at
      ])

      transaction?(false)
    end

    atomic_in_tx_update :consume_in_tx do
      accept([])
      argument(:at, :utc_datetime_usec, allow_nil?: false)

      argument(:successor_ciphertext, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [trim?: false]
      )

      argument(:successor_retry_until, :utc_datetime_usec, allow_nil?: false)
      change(filter(expr(is_nil(consumed_at) and ^arg(:at) < expires_at)))
      change(set_attribute(:consumed_at, arg(:at)))
      change(set_attribute(:successor_ciphertext, arg(:successor_ciphertext)))
      change(set_attribute(:successor_retry_until, arg(:successor_retry_until)))
    end

    atomic_in_tx_update :redact_successor_in_tx do
      accept([])
      argument(:at, :utc_datetime_usec, allow_nil?: false)
      change(filter(expr(successor_retry_until < ^arg(:at) and not is_nil(successor_ciphertext))))
      change(set_attribute(:successor_ciphertext, nil))
    end

    destroy :remove_in_tx do
      transaction?(false)
      require_atomic?(true)
    end
  end
end
