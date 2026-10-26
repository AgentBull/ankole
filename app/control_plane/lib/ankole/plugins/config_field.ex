defmodule Ankole.Plugins.ConfigField do
  @moduledoc "The configuration-field vocabulary published by plugin adapters to browser forms."
  alias Ankole.Ash.Types.{StringMap, JSONValue}

  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        path: [type: :string, allow_nil?: false],
        type: [type: :string, allow_nil?: false],
        label: [type: StringMap],
        description: [type: StringMap],
        default: [type: JSONValue],
        advanced: [type: :boolean],
        required: [type: :boolean],
        encrypted: [type: :boolean],
        min: [type: :integer],
        max: [type: :integer],
        requiredWhen: [
          type: {:array, :map},
          constraints: [
            items: [fields: [path: [type: :string, allow_nil?: false], value: [type: JSONValue]]]
          ]
        ],
        options: [
          type: {:array, :map},
          constraints: [
            items: [
              fields: [
                value: [type: :string, allow_nil?: false],
                label: [type: StringMap],
                description: [type: StringMap]
              ]
            ]
          ]
        ],
        validation: [
          type: :union,
          constraints: [
            types: [
              pattern: [
                type: :map,
                tag: :kind,
                tag_value: "pattern",
                constraints: [
                  fields: [
                    kind: [type: :atom, allow_nil?: false, constraints: [one_of: [:pattern]]],
                    message: [type: StringMap, allow_nil?: false],
                    pattern: [type: :string, allow_nil?: false]
                  ]
                ]
              ],
              json_object: [
                type: :map,
                tag: :kind,
                tag_value: "json_object",
                constraints: [
                  fields: [
                    kind: [type: :atom, allow_nil?: false, constraints: [one_of: [:json_object]]],
                    message: [type: StringMap, allow_nil?: false],
                    requiredStringProperties: [type: {:array, :string}],
                    stringPrefixes: [type: StringMap]
                  ]
                ]
              ]
            ]
          ]
        ]
      ]
    ]
end
