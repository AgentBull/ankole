defmodule Ankole.AuthZ.Membership do
  @moduledoc "Static Principal membership in an AuthZ group."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.AuthZ,
    extensions: [AshJsonApi.Resource]

  json_api do
    type("principal_group_membership")
    derive_filter?(false)
    derive_sort?(false)

    primary_key do
      keys([:group_id, :principal_uid])
    end

    default_fields([:group_id, :principal_uid, :inserted_at])
  end

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
      upsert?(true)
      upsert_fields([:principal_uid])
    end

    destroy :remove_in_tx do
      require_atomic?(true)
    end
  end

  @type t :: %__MODULE__{}
end
