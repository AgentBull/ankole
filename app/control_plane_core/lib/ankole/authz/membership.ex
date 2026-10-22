defmodule Ankole.AuthZ.Membership do
  @moduledoc "Static Principal membership in an AuthZ group."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.AuthZ.Domain

  postgres do
    table("principal_group_memberships")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names([
      {:group_id, "principal_group_memberships_group_id_fkey"},
      {:principal_uid, "principal_group_memberships_principal_uid_fkey"}
    ])

    unique_index_names([{[:principal_uid, :group_id], "principal_group_memberships_pkey"}])
  end

  attributes do
    attribute(:group_id, Ankole.Ash.Types.UUIDv7,
      public?: true,
      primary_key?: true,
      allow_nil?: false
    )

    attribute(:principal_uid, Ankole.Ash.Types.PrincipalKey,
      public?: true,
      primary_key?: true,
      allow_nil?: false
    )

    create_timestamp(:inserted_at, type: :utc_datetime_usec)
  end

  relationships do
    belongs_to(:group, Ankole.AuthZ.Group, define_attribute?: false)

    belongs_to :principal, Ankole.Principals.Principal do
      source_attribute(:principal_uid)
      destination_attribute(:uid)
      define_attribute?(false)
    end
  end

  actions do
    defaults([:read])

    create :add_in_tx do
      accept([:group_id, :principal_uid])
      transaction?(false)
      change(Ankole.Ash.RequireTransaction)
      upsert?(true)
      upsert_fields([:principal_uid])
    end

    destroy :remove_in_tx do
      transaction?(false)
      require_atomic?(true)
      change(Ankole.Ash.RequireTransaction.Atomic)
    end
  end

  @type t :: %__MODULE__{}
end
