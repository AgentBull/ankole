defmodule Ankole.Signals.ConsoleBinding do
  @moduledoc "An operator projection of a Signal Binding."
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        id: [type: Ankole.Ash.Types.UUIDv7, allow_nil?: false],
        routing_mode: [
          type: :atom,
          constraints: [one_of: [:ai_colleague, :sender_personal_assistant]],
          allow_nil?: false
        ],
        adapter: [
          type: :string,
          constraints: [trim?: false, allow_empty?: true],
          allow_nil?: false
        ],
        agent_uid: [type: :string],
        config_key: [type: :string, constraints: [trim?: false, allow_empty?: true]],
        config_ref: [
          type: :string,
          constraints: [trim?: false, allow_empty?: true],
          allow_nil?: false
        ],
        enabled: [type: :boolean, allow_nil?: false],
        filters: [type: Ankole.Ash.Types.JSONValue],
        name: [
          type: :string,
          constraints: [trim?: false, allow_empty?: true],
          allow_nil?: false
        ],
        target: [type: Ankole.Ash.Types.JSONValue],
        unaddressed_group_message_policy: [
          type: :atom,
          constraints: [one_of: [:ignore, :record_only, :may_intervene]],
          allow_nil?: false
        ],
        unavailable_reason: [
          type: :string,
          constraints: [trim?: false, allow_empty?: true]
        ],
        unmatched_sender_policy: [
          type: :atom,
          constraints: [one_of: [:manual_review, :create_standalone]],
          allow_nil?: false
        ]
      ]
    ]
end
