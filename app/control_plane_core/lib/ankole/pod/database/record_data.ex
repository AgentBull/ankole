defmodule Ankole.Pod.Database.RecordData do
  @moduledoc "Cell values keyed by the user's field IDs."
  use Ash.Type.NewType, subtype_of: Ankole.Ash.Types.JSONMap
  use AshJsonApi.Type

  @impl true
  def json_schema(_),
    do: %OpenApiSpex.Schema{
      type: :object,
      additionalProperties: Ankole.Pod.Database.Value.json_schema([])
    }

  @impl true
  def json_write_schema(_), do: %{"type" => "object"}
end
