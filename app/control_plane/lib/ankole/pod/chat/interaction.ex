defmodule Ankole.Pod.Chat.Interaction do
  @moduledoc "A question that waits for a room member's answer."
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        interaction_id: [type: :string, allow_nil?: false],
        messageID: [type: Ankole.Ash.Types.UUIDv7, allow_nil?: false],
        agentUID: [type: Ankole.Ash.Types.PrincipalKey],
        tool_call_id: [type: :string, allow_nil?: false],
        question: [type: :string, allow_nil?: false],
        allow_free_text: [type: :boolean, allow_nil?: false],
        state: [type: :string, allow_nil?: false],
        choices: [
          type: {:array, :map},
          allow_nil?: false,
          constraints: [
            items: [
              fields: [
                id: [type: :string, allow_nil?: false],
                label: [type: :string, allow_nil?: false],
                description: [type: :string]
              ]
            ]
          ]
        ]
      ]
    ]
end
