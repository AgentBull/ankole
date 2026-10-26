defmodule Ankole.Ash.Types.StringMap do
  @moduledoc "A JSON dictionary whose values are strings, such as localized plugin text."
  use Ash.Type.NewType, subtype_of: Ankole.Ash.Types.JSONMap
  use AshJsonApi.Type

  @impl AshJsonApi.Type
  def json_schema(_),
    do: %OpenApiSpex.Schema{
      type: :object,
      additionalProperties: %OpenApiSpex.Schema{type: :string}
    }

  @impl AshJsonApi.Type
  def json_write_schema(_),
    do: %{"type" => "object", "additionalProperties" => %{"type" => "string"}}

  @impl Ash.Type
  def apply_constraints(nil, _), do: {:ok, nil}

  def apply_constraints(value, _) do
    if Enum.all?(value, fn {_key, text} -> is_binary(text) end),
      do: {:ok, value},
      else: {:error, message: "values must be strings"}
  end
end
