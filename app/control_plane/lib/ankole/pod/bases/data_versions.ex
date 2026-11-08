defmodule Ankole.Pod.Bases.DataVersions do
  @moduledoc "Table data versions keyed by the ID of every table an aggregate read."
  use Ash.Type.NewType, subtype_of: Ankole.Ash.Types.JSONMap
  use AshJsonApi.Type

  @impl true
  def json_schema(_),
    do: %OpenApiSpex.Schema{
      type: :object,
      additionalProperties: %OpenApiSpex.Schema{type: :integer}
    }

  @impl true
  def json_write_schema(_),
    do: %{"type" => "object", "additionalProperties" => %{"type" => "integer"}}
end
