defmodule Ankole.Pod.Chat.Detail do
  @moduledoc "A room snapshot with history and each Agent's queue and current work."
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        activities: [type: {:array, Ankole.Pod.Chat.Activity}, allow_nil?: false],
        pendingInteractions: [type: {:array, Ankole.Pod.Chat.Interaction}, allow_nil?: false],
        latestInput: [
          type: :map,
          constraints: [
            fields: [
              messageID: [type: Ankole.Ash.Types.UUIDv7, allow_nil?: false],
              authorUID: [type: Ankole.Ash.Types.PrincipalKey],
              agentUIDs: [type: {:array, Ankole.Ash.Types.PrincipalKey}, allow_nil?: false]
            ]
          ]
        ],
        linkedRuns: [
          type: {:array, :map},
          allow_nil?: false,
          constraints: [
            items: [
              fields: [
                id: [type: :string, allow_nil?: false],
                kind: [
                  type: :atom,
                  allow_nil?: false,
                  constraints: [one_of: [:background_agent_job, :workflow]]
                ],
                title: [type: :string, allow_nil?: false],
                agentUID: [type: Ankole.Ash.Types.PrincipalKey, allow_nil?: false],
                status: [type: :string, allow_nil?: false],
                sourceSignalID: [type: Ankole.Ash.Types.UUIDv7],
                sourceMessageID: [type: Ankole.Ash.Types.UUIDv7],
                text: [type: :string],
                createdAt: [type: :utc_datetime_usec, allow_nil?: false],
                updatedAt: [type: :utc_datetime_usec, allow_nil?: false]
              ]
            ]
          ]
        ],
        pendingQueues: [
          type: {:array, :map},
          allow_nil?: false,
          constraints: [
            items: [
              fields: [
                agentUID: [type: Ankole.Ash.Types.PrincipalKey, allow_nil?: false],
                queueVersion: [type: :string, allow_nil?: false],
                retryableMessageID: [type: Ankole.Ash.Types.UUIDv7],
                paused: [type: :boolean, allow_nil?: false],
                workStatus: [
                  type: :map,
                  allow_nil?: false,
                  constraints: [
                    fields: [
                      state: [
                        type: :atom,
                        allow_nil?: false,
                        constraints: [one_of: [:idle, :queued, :running, :retrying]]
                      ],
                      retryAt: [type: :utc_datetime_usec]
                    ]
                  ]
                ],
                inputs: [type: {:array, Ankole.Pod.Chat.QueuedInput}, allow_nil?: false]
              ]
            ]
          ]
        ],
        conversation: [type: Ankole.Pod.Chat.Conversation, allow_nil?: false],
        artifacts: [
          type: :map,
          allow_nil?: false,
          constraints: [
            fields: [
              pageIDs: [type: {:array, Ankole.Ash.Types.UUIDv7}, allow_nil?: false],
              attachments: [
                type: {:array, :map},
                allow_nil?: false,
                constraints: [
                  items: [
                    fields: [
                      messageID: [type: Ankole.Ash.Types.UUIDv7, allow_nil?: false],
                      attachments: [type: {:array, Ankole.Pod.Chat.Attachment}, allow_nil?: false]
                    ]
                  ]
                ]
              ]
            ]
          ]
        ],
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
        ]
      ]
    ]
end
