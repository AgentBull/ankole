defmodule Ankole.Pod.Chat.Link do
  @moduledoc "A page reference or quoted message carried by a Chat input."
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        kind: [type: :atom, allow_nil?: false, constraints: [one_of: [:page, :message]]],
        id: [type: Ankole.Ash.Types.UUIDv7, allow_nil?: false],
        quote: [type: :string, constraints: [trim?: false, allow_empty?: true]]
      ]
    ]
end
