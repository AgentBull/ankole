defmodule Ankole.Pod.Database.Value do
  @moduledoc "A user-defined Database cell value. Its structure is owned by the field definition."
  use Ash.Type.NewType, subtype_of: Ankole.Ash.Types.JSONValue
  use AshJsonApi.Type

  @impl true
  def json_schema(_) do
    %OpenApiSpex.Schema{
      anyOf: [
        %OpenApiSpex.Schema{type: :string},
        %OpenApiSpex.Schema{type: :number},
        %OpenApiSpex.Schema{type: :boolean},
        %OpenApiSpex.Schema{type: :null},
        %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{}},
        %OpenApiSpex.Schema{type: :object, additionalProperties: true}
      ]
    }
  end

  @impl true
  def json_write_schema(_), do: %{}
end
