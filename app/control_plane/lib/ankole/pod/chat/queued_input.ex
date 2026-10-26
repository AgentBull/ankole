defmodule Ankole.Pod.Chat.QueuedInput do
  @moduledoc "A human input that is queued for one Agent."
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        messageID: [type: Ankole.Ash.Types.UUIDv7, allow_nil?: false],
        agentUID: [type: Ankole.Ash.Types.PrincipalKey, allow_nil?: false],
        authorUID: [type: Ankole.Ash.Types.PrincipalKey],
        text: [type: :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true]],
        modelProfile: [type: :string, allow_nil?: false],
        deliveryMode: [type: :atom, allow_nil?: false, constraints: [one_of: [:steer, :queue]]],
        mentions: [type: {:array, Ankole.Pod.Chat.Mention}, allow_nil?: false],
        links: [type: {:array, Ankole.Pod.Chat.Link}, allow_nil?: false],
        attachments: [type: {:array, Ankole.Pod.Chat.Attachment}, allow_nil?: false]
      ]
    ]
end
