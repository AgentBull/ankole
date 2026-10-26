defmodule Ankole.Pod.Chat.Mention do
  @moduledoc "A named Principal mention carried by a Chat input."
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        type: [type: :atom, allow_nil?: false, constraints: [one_of: [:human, :agent]]],
        uid: [type: Ankole.Ash.Types.PrincipalKey, allow_nil?: false],
        displayName: [type: :string, constraints: [trim?: false]]
      ]
    ]
end
