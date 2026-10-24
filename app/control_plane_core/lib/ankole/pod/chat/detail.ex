defmodule Ankole.Pod.Chat.Detail do
  @moduledoc "A conversation snapshot: history window, input queue, and current work status."
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        conversation: [type: Ankole.Pod.Chat.Conversation, allow_nil?: false],
        messages: [type: {:array, Ankole.Pod.Chat.Message}, allow_nil?: false],
        removedMessageIDs: [type: {:array, Ankole.Ash.Types.UUIDv7}, allow_nil?: false],
        olderMessagesBeforeSeq: [type: :integer],
        messageRange: [
          type: :map,
          allow_nil?: false,
          constraints: [
            fields: [
              firstSeq: [type: :integer, allow_nil?: false],
              lastSeq: [type: :integer, allow_nil?: false]
            ]
          ]
        ],
        queuePaused: [type: :boolean, allow_nil?: false],
        queueVersion: [type: :string, allow_nil?: false],
        retryableMessageID: [type: Ankole.Ash.Types.UUIDv7],
        pendingInputs: [
          type: {:array, :map},
          allow_nil?: false,
          constraints: [
            items: [
              fields: [
                messageID: [type: Ankole.Ash.Types.UUIDv7, allow_nil?: false],
                text: [
                  type: :string,
                  allow_nil?: false,
                  constraints: [trim?: false, allow_empty?: true]
                ],
                modelProfile: [type: :string, allow_nil?: false],
                deliveryMode: [
                  type: :atom,
                  allow_nil?: false,
                  constraints: [one_of: [:steer, :queue]]
                ],
                attachments: [type: {:array, Ankole.Pod.Chat.Attachment}, allow_nil?: false]
              ]
            ]
          ]
        ],
        status: [
          type: :map,
          allow_nil?: false,
          constraints: [
            fields: [
              state: [
                type: :atom,
                allow_nil?: false,
                constraints: [one_of: [:idle, :queued, :running, :retrying]]
              ],
              retryAt: [type: :utc_datetime_usec],
              activity: [type: Ankole.Pod.Chat.Activity, allow_nil?: false]
            ]
          ]
        ]
      ]
    ]
end
