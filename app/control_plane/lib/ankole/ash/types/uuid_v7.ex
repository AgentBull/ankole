defmodule Ankole.Ash.Types.UUIDv7 do
  @moduledoc "Uses the Ecto UUID codec with Ash UUIDv7 generation."
  use Ash.Type.NewType, subtype_of: :uuid

  @impl true
  def ecto_type, do: Ankole.Ecto.UUIDv7
end
