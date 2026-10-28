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
        scope: [type: :atom, allow_nil?: false, constraints: [one_of: ~w(global tenant pod)a]],
        editable: [type: :boolean, allow_nil?: false],
        default_present: [type: :boolean, allow_nil?: false],
        overridden: [type: :boolean, allow_nil?: false],
        present: [type: :boolean, allow_nil?: false],
        source: [
          type: :atom,
          allow_nil?: false,
          constraints: [one_of: ~w(agent tenant global default pattern missing error)a]
        ],
        fallback_present: [type: :boolean],
        fallback_source: [type: :string],
        fallback_value: [type: Ankole.Ash.Types.JSONValue],
        agent_override_supported: [type: :boolean],
        public_value: [type: Ankole.Ash.Types.JSONValue],
        secret_present: [type: :boolean],
        runtime_status: [type: :string],
        value: [type: Ankole.Ash.Types.JSONValue],
        error: [type: :string]
      ]
    ]
end
