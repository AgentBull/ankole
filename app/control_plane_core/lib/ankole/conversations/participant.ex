defmodule Ankole.Conversations.Participant do
  @moduledoc "A Principal's immutable membership of one shared conversation."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.Conversations.Domain

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
      constraints: [one_of: [:owner, :member, :agent]],
      allow_nil?: false,
      public?: true
    )
  end

  actions do
    defaults([:read])

    create_if_absent :join do
      transaction?(false)
      change(Ankole.Ash.RequireTransaction)
      accept([:conversation_id, :principal_uid, :role])
    end
  end
end
