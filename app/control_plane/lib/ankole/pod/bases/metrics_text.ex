defmodule Ankole.Pod.Bases.MetricsText do
  @moduledoc "Exact decimal or scalar text representations keyed by metric alias."
  use Ash.Type.NewType, subtype_of: Ankole.Ash.Types.JSONMap
  use AshJsonApi.Type

  @impl true
  def json_schema(_),
    do: %OpenApiSpex.Schema{
      type: :object,
      additionalProperties: %OpenApiSpex.Schema{
        anyOf: [
          %OpenApiSpex.Schema{type: :string},
          %OpenApiSpex.Schema{type: :null}
        ]
      }
    }

  @impl true
  def json_write_schema(_),
    do: %{
      "type" => "object",
      "additionalProperties" => %{"type" => ["string", "null"]}
    }
end
