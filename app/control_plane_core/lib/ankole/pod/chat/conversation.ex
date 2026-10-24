defmodule Ankole.Pod.Chat.Conversation do
  @moduledoc "A human's conversation list entry, including the current agent status."
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        id: [type: Ankole.Ash.Types.UUIDv7, allow_nil?: false],
        title: [type: :string, constraints: [trim?: false, allow_empty?: true], allow_nil?: false],
        pageID: [type: Ankole.Ash.Types.UUIDv7],
        lastActivityAt: [type: :utc_datetime_usec, allow_nil?: false],
        agent: [
          type: :map,
          allow_nil?: false,
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
