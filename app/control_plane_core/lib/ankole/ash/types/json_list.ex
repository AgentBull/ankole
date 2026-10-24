defmodule Ankole.Ash.Types.JSONList do
  @moduledoc "Stores an Ash-validated JSON array in one JSONB value for atomic SQL updates."
  use Ash.Type
  use AshJsonApi.Type

  @impl true
  def storage_type(_constraints), do: :map

  @impl true
  def cast_atomic(value, constraints) do
    if Ash.Expr.expr?(value), do: {:atomic, value}, else: cast_input(value, constraints)
  end

  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}

  def cast_input(value, _constraints) when is_list(value),
    do: Ash.Type.cast_input({:array, Ankole.Ash.Types.JSONValue}, value, nil_items?: true)

  def cast_input(_value, _constraints), do: :error

  @impl true
  def cast_stored(value, constraints), do: cast_input(value, constraints)
  @impl true
  def dump_to_native(value, constraints), do: cast_input(value, constraints)

  @impl AshJsonApi.Type
  def json_schema(_constraints),
    do: %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{}}

  @impl AshJsonApi.Type
  def json_write_schema(_constraints), do: %{"type" => "array", "items" => %{}}
end
