defmodule Ankole.AppConfigure.ConsoleItem do
  @moduledoc "The safe operator view of one registered setting."
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        key: [type: :string, allow_nil?: false],
        kind: [
          type: :atom,
          allow_nil?: false,
          constraints: [one_of: ~w(exact pattern pattern_concrete)a]
        ],
        pattern: [type: :string],
        pattern_id: [type: :string],
        description: [type: :string],
        encrypted: [type: :boolean, allow_nil?: false],
        scope: [type: :atom, allow_nil?: false, constraints: [one_of: ~w(global tenant)a]],
        editable: [type: :boolean, allow_nil?: false],
        default_present: [type: :boolean, allow_nil?: false],
        overridden: [type: :boolean, allow_nil?: false],
        present: [type: :boolean, allow_nil?: false],
        source: [
          type: :atom,
          allow_nil?: false,
          constraints: [one_of: ~w(tenant global default pattern missing error)a]
        ],
        value: [type: Ankole.Ash.Types.JSONValue],
        error: [type: :string]
      ]
    ]
end
