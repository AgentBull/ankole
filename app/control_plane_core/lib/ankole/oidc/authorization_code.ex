defmodule Ankole.OIDC.AuthorizationCode do
  @moduledoc false
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.OIDC.Domain

  postgres do
    table("oidc_authorization_codes")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names(
      client_id: "oidc_authorization_codes_client_id_fkey",
      principal_uid: "oidc_authorization_codes_principal_uid_fkey",
      session_id: "oidc_authorization_codes_session_id_fkey",
      family_id: "oidc_authorization_codes_family_id_fkey"
    )

    check_constraints do
      check_constraint(:code_challenge, "oidc_authorization_codes_pkce_s256")
      check_constraint(:finalized, "oidc_authorization_codes_finalization")
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

    attribute(:redirect_uri, :string,
      public?: true,
      allow_nil?: false,
      constraints: [trim?: false]
    )

    attribute(:scope, :string, public?: true, allow_nil?: false, constraints: [trim?: false])
    attribute(:nonce, :string, public?: true, constraints: [trim?: false, allow_empty?: true])

    attribute(:code_challenge, :string,
      public?: true,
      allow_nil?: false,
      constraints: [match: ~r/^[A-Za-z0-9_-]{43}$/]
    )

    attribute(:expires_at, :utc_datetime_usec, public?: true, allow_nil?: false)
    attribute(:consumed_at, :utc_datetime_usec, public?: true)
    attribute(:finalized, :boolean, public?: true, allow_nil?: false, default: false)
    attribute(:family_id, :string, public?: true, constraints: [trim?: false])
    attribute(:replay_retain_until, :utc_datetime_usec, public?: true)
    create_timestamp(:inserted_at, type: :utc_datetime_usec)
  end

  actions do
    defaults([:read])

    create :issue_in_tx do
      accept([
        :digest,
        :client_id,
        :principal_uid,
        :session_id,
        :redirect_uri,
        :scope,
        :nonce,
        :code_challenge,
        :expires_at
      ])

      transaction?(false)
    end

    atomic_in_tx_update :consume_in_tx do
      accept([])
      argument(:at, :utc_datetime_usec, allow_nil?: false)
      change(filter(expr(is_nil(consumed_at))))
      change(set_attribute(:consumed_at, arg(:at)))
    end

    atomic_in_tx_update :finalize_in_tx do
      accept([])
      argument(:family_id, :string, constraints: [trim?: false])
      argument(:replay_retain_until, :utc_datetime_usec, allow_nil?: false)
      change(filter(expr(not finalized and not is_nil(consumed_at))))
      change(set_attribute(:finalized, true))
      change(set_attribute(:family_id, arg(:family_id)))
      change(set_attribute(:replay_retain_until, arg(:replay_retain_until)))
    end

    destroy :expire_in_tx do
      transaction?(false)
      require_atomic?(true)
    end
  end
end
