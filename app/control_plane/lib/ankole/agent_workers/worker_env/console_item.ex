defmodule Ankole.AgentWorkers.WorkerEnv.ConsoleItem do
  @moduledoc "An operator variable and its effective source, without encrypted material."
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        name: [type: :string, allow_nil?: false],
        secret: [type: :boolean, allow_nil?: false],
        description: [type: :string],
        present: [type: :boolean, allow_nil?: false],
        source: [
          type: :atom,
          allow_nil?: false,
          constraints: [one_of: ~w(global tenant agent missing)a]
        ],
        value: [type: :string, constraints: [trim?: false, allow_empty?: true]]
      ]
    ]
end
