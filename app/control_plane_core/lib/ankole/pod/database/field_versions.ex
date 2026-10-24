defmodule Ankole.Pod.Database.FieldVersions do
  @moduledoc "Optimistic concurrency versions keyed by the user's field IDs."
  use Ash.Type
  use AshJsonApi.Type

  @impl true
  def storage_type(_), do: :map
  @impl true
  def cast_input(nil, _), do: {:ok, nil}

  def cast_input(value, _) when is_map(value) and not is_struct(value) do
    if Enum.all?(value, fn {id, version} ->
         is_binary(id) and is_integer(version) and version >= 0
       end),
       do: {:ok, value},
       else: {:error, message: "must map field IDs to non-negative versions"}
  end

  def cast_input(_, _), do: :error
  @impl true
  def cast_stored(value, constraints), do: cast_input(value, constraints)
  @impl true
  def dump_to_native(value, constraints), do: cast_input(value, constraints)
  @impl true
  def json_schema(_),
    do: %OpenApiSpex.Schema{
      type: :object,
      additionalProperties: %OpenApiSpex.Schema{type: :integer, minimum: 0}
    }

  @impl true
  def json_write_schema(_),
    do: %{"type" => "object", "additionalProperties" => %{"type" => "integer", "minimum" => 0}}
end
