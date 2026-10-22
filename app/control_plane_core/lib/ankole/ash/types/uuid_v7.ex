defmodule Ankole.Ash.Types.UUIDv7 do
  @moduledoc "Uses the shared UUID codec and native UUIDv7 generator."
  use Ash.Type.NewType, subtype_of: :uuid

  @impl true
  def ecto_type, do: Ankole.Ecto.UUIDv7
end
