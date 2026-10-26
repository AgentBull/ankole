defmodule Ankole.Pod.Chat.Message do
  @moduledoc "A committed message in a human's conversation history."
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        id: [type: Ankole.Ash.Types.UUIDv7, allow_nil?: false],
        seq: [type: :integer, allow_nil?: false],
        authorType: [
          type: :atom,
          allow_nil?: false,
          constraints: [one_of: [:human, :agent, :system]]
        ],
        authorDisplayName: [type: :string, allow_nil?: false],
        authorArchived: [type: :boolean, allow_nil?: false],
        richContent: [type: Ankole.Ash.Types.JSONMap],
        savedPages: [
          type: {:array, :map},
          allow_nil?: false,
          constraints: [
            items: [
              fields: [
                id: [type: Ankole.Ash.Types.UUIDv7, allow_nil?: false],
                title: [type: :string, allow_nil?: false, constraints: [allow_empty?: true]]
              ]
            ]
          ]
        ],
        mentions: [type: {:array, Ankole.Ash.Types.JSONMap}, allow_nil?: false],
        authorUID: [type: Ankole.Ash.Types.PrincipalKey],
        kind: [type: :atom, allow_nil?: false, constraints: [one_of: [:message, :notice]]],
        text: [type: :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true]],
        createdAt: [type: :utc_datetime_usec, allow_nil?: false],
        signalID: [type: Ankole.Ash.Types.UUIDv7],
        replyToMessageID: [type: Ankole.Ash.Types.UUIDv7],
        links: [type: {:array, Ankole.Pod.Chat.Link}, allow_nil?: false],
        attachments: [type: {:array, Ankole.Pod.Chat.Attachment}, allow_nil?: false]
      ]
    ]
end
