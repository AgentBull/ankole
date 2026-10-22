defmodule Ankole.OIDC.RefreshTokenFamily do
  @moduledoc false
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.OIDC.Domain

  postgres do
    table("oidc_refresh_token_families")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names(session_id: "oidc_refresh_token_families_session_id_fkey")
  end

  attributes do
    attribute(:id, :string,
      primary_key?: true,
      public?: true,
      allow_nil?: false,
      constraints: [trim?: false]
    )

    attribute(:session_id, Ankole.Ash.Types.UUIDv7, public?: true, allow_nil?: false)
    attribute(:family_expires_at, :utc_datetime_usec, public?: true, allow_nil?: false)
    attribute(:revoked_at, :utc_datetime_usec, public?: true)
  end

  actions do
    defaults([:read])

    create :issue_in_tx do
      accept([:id, :session_id, :family_expires_at])
      transaction?(false)
      change(Ankole.Ash.RequireTransaction)
    end

    atomic_in_tx_update :revoke_in_tx do
      accept([])
      argument(:at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
      change(atomic_update(:revoked_at, expr(fragment("COALESCE(?, ?)", revoked_at, ^arg(:at)))))
    end
  end
end
