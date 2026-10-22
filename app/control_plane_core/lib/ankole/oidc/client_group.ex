defmodule Ankole.OIDC.ClientGroup do
  @moduledoc false
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.OIDC.Domain

  postgres do
    table("oidc_client_groups")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names([
      {:client_id, "oidc_client_groups_client_id_fkey"},
      {:group_id, "oidc_client_groups_group_id_fkey"}
    ])
  end

  attributes do
    attribute(:client_id, Ankole.Ash.Types.UUIDv7,
      public?: true,
      primary_key?: true,
      allow_nil?: false
    )

    attribute(:group_id, Ankole.Ash.Types.UUIDv7,
      public?: true,
      primary_key?: true,
      allow_nil?: false
    )

    create_timestamp(:inserted_at, type: :utc_datetime_usec)
  end

  actions do
    defaults([:read])

    create :link_in_tx do
      accept([:client_id, :group_id])
      transaction?(false)
      change(Ankole.Ash.RequireTransaction)
    end

    destroy :unlink_in_tx do
      transaction?(false)
      require_atomic?(true)
      change(Ankole.Ash.RequireTransaction.Atomic)
    end
  end

  @type t :: %__MODULE__{}
end
