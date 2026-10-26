defmodule Ankole.Conversations.Participant do
  @moduledoc "A room member or viewer and that Principal's personal preferences."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.Conversations

  postgres do
    table("conversation_participants")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names([
      {:conversation_id, "conversation_participants_conversation_id_fkey"},
      {:principal_uid, "conversation_participants_principal_uid_fkey"}
    ])

    unique_index_names([
      {[:tenant_id, :conversation_id, :principal_uid], "conversation_participants_pkey"}
    ])

    check_constraints do
      check_constraint(:role, "conversation_participants_role_check")
    end
  end

  attributes do
    attribute(:conversation_id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      public?: true
    )

    attribute(:principal_uid, Ankole.Ash.Types.PrincipalKey,
      primary_key?: true,
      allow_nil?: false,
      public?: true
    )

    attribute(:role, :atom,
      constraints: [one_of: [:owner, :member, :agent, :observer]],
      allow_nil?: false,
      public?: true
    )

    attribute(:may_intervene, :boolean, default: false, allow_nil?: false, public?: true)
    attribute(:pinned_at, :utc_datetime_usec, public?: true)
    attribute(:muted, :boolean, default: false, allow_nil?: false, public?: true)

    attribute(:last_read_seq, :integer,
      default: 0,
      allow_nil?: false,
      constraints: [min: 0],
      public?: true
    )
  end

  actions do
    defaults([:read])

    update :participate do
      accept([])
      change(set_attribute(:role, :member))
    end

    update :update_preferences do
      accept([:pinned_at, :muted, :last_read_seq])
    end

    update :set_may_intervene do
      accept([:may_intervene])
      validate(attribute_equals(:role, :agent))
    end

    destroy :leave do
      require_atomic?(true)
    end

    create_if_absent :join do
      accept([:conversation_id, :principal_uid, :role, :may_intervene])
    end
  end
end
