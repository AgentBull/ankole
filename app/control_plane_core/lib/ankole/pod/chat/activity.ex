defmodule Ankole.Pod.Chat.Activity do
  @moduledoc "The current, bounded activity projection shared with the conversation stream."
  @item [
    operation_id: [type: :string, allow_nil?: false],
    phase: [type: :string],
    state: [type: :string],
    consequential: [type: :boolean],
    label_key: [type: :string],
    label: [type: :string],
    label_bindings: [type: Ankole.Ash.Types.JSONMap]
  ]
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        conversationID: [type: Ankole.Ash.Types.UUIDv7, allow_nil?: false],
        agentUID: [type: Ankole.Ash.Types.PrincipalKey, allow_nil?: false],
        sessionID: [type: :string, allow_nil?: false],
        signalID: [type: Ankole.Ash.Types.UUIDv7],
        responseID: [type: :string],
        epoch: [type: :integer, allow_nil?: false],
        revision: [type: :integer, allow_nil?: false],
        state: [
          type: :atom,
          allow_nil?: false,
          constraints: [one_of: [:active, :unavailable, :settled]]
        ],
        phase: [type: :map, constraints: [fields: @item]],
        tools: [
          type: {:array, :map},
          allow_nil?: false,
          constraints: [max_length: 4, items: [fields: @item]]
        ]
      ]
    ]
end
