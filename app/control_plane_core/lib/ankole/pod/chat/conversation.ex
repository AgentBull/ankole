defmodule Ankole.Pod.Chat.Conversation do
  @moduledoc "A room list entry with membership, personal preferences, and current work status."
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        id: [type: Ankole.Ash.Types.UUIDv7, allow_nil?: false],
        title: [type: :string, constraints: [trim?: false, allow_empty?: true], allow_nil?: false],
        roomMode: [type: :atom, allow_nil?: false, constraints: [one_of: [:dm, :group]]],
        accessScope: [
          type: :atom,
          allow_nil?: false,
          constraints: [one_of: [:participants, :anchor_page]]
        ],
        titleCustomized: [type: :boolean, allow_nil?: false],
        canDelete: [type: :boolean, allow_nil?: false],
        canManage: [type: :boolean, allow_nil?: false],
        createdBy: [type: Ankole.Ash.Types.PrincipalKey, allow_nil?: false],
        lastMessageSeq: [type: :integer, allow_nil?: false],
        rowStatus: [type: :string, allow_nil?: false],
        viewer: [
          type: :map,
          allow_nil?: false,
          constraints: [
            fields: [
              uid: [type: Ankole.Ash.Types.PrincipalKey, allow_nil?: false],
              pinned: [type: :boolean, allow_nil?: false],
              muted: [type: :boolean, allow_nil?: false],
              lastReadSeq: [type: :integer, allow_nil?: false]
            ]
          ]
        ],
        agents: [type: {:array, Ankole.Pod.Chat.Member}, allow_nil?: false],
        participants: [type: {:array, Ankole.Pod.Chat.Member}, allow_nil?: false],
        pageID: [type: Ankole.Ash.Types.UUIDv7],
        lastActivityAt: [type: :utc_datetime_usec, allow_nil?: false],
        agent: [
          type: :map,
          constraints: [
            fields: [
              uid: [type: Ankole.Ash.Types.PrincipalKey, allow_nil?: false],
              displayName: [type: :string, allow_nil?: false],
              active: [type: :boolean, allow_nil?: false]
            ]
          ]
        ]
      ]
    ]
end
