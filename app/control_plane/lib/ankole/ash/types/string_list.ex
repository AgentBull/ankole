defmodule Ankole.Ash.Types.StringList do
  @moduledoc "Stores an Ash-validated string array in one JSONB value for atomic SQL updates."
  use Ash.Type

  @impl true
  def storage_type(_constraints), do: :map

  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}

  def cast_input(value, _constraints) when is_list(value),
    do: Ash.Type.cast_input({:array, :string}, value, items: [trim?: false, allow_empty?: true])

  def cast_input(_value, _constraints), do: :error

  @impl true
  def cast_atomic(value, constraints) do
    if Ash.Expr.expr?(value), do: {:atomic, value}, else: cast_input(value, constraints)
  end

  @impl true
  def cast_stored(value, constraints), do: cast_input(value, constraints)
  @impl true
  def dump_to_native(value, constraints), do: cast_input(value, constraints)
end
