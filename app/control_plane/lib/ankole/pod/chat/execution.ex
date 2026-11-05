defmodule Ankole.Pod.Chat.Execution do
  @moduledoc """
  The work summary of one Agent Turn: its steps, the model that served it, and
  the usage that the AIGateway ledger counted for its Signal.

  A step's `input` and `output` are excerpts of JSON or text. A token count is
  `nil` when no round of the Turn reported it.
  """
  @text [type: :string, constraints: [allow_empty?: true, trim?: false]]
  @required_text [
    type: :string,
    allow_nil?: false,
    constraints: [allow_empty?: true, trim?: false]
  ]
  @usage [
    rounds: [type: :integer, allow_nil?: false],
    reported_rounds: [type: :integer, allow_nil?: false],
    input_tokens: [type: :integer],
    output_tokens: [type: :integer],
    cached_input_tokens: [type: :integer],
    reasoning_tokens: [type: :integer]
  ]
  @model_usage @usage ++
                 [
                   model: [type: :string, allow_nil?: false],
                   provider_model: [type: :string],
                   model_profile: [type: :string],
                   served_profile: [type: :string]
                 ]
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        duration_ms: [type: :integer],
        status: [type: :string],
        thinking_summary: @text,
        model: [type: :string],
        steps: [
          type: {:array, :map},
          constraints: [
            items: [
              fields: [
                id: @required_text,
                tool: @required_text,
                title: @required_text,
                status: @required_text,
                duration_ms: [type: :integer],
                input: @text,
                output: @text
              ]
            ]
          ]
        ],
        usage: [
          type: :map,
          constraints: [
            fields:
              @usage ++
                [
                  models: [
                    type: {:array, :map},
                    allow_nil?: false,
                    constraints: [items: [fields: @model_usage]]
                  ]
                ]
          ]
        ]
      ]
    ]
end
