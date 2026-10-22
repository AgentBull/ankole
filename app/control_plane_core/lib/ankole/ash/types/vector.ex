defmodule Ankole.Ash.Types.Vector do
  @moduledoc "Uses the existing Pgvector codec and Postgrex extension for durable vectors."
  use Ash.Type

  @impl true
  def storage_type(_constraints), do: :vector
  @impl true
  def ecto_type, do: Pgvector.Ecto.Vector

  @impl true
  def cast_atomic(value, constraints) do
    if Ash.Expr.expr?(value), do: {:atomic, value}, else: cast_input(value, constraints)
  end

  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}
  def cast_input(%Pgvector{} = value, _constraints), do: Pgvector.Ecto.Vector.cast(value)

  def cast_input(value, _constraints) when is_list(value) do
    if Enum.all?(value, &is_number/1), do: Pgvector.Ecto.Vector.cast(value), else: :error
  end

  def cast_input(_value, _constraints), do: :error

  @impl true
  def cast_stored(nil, _constraints), do: {:ok, nil}
  def cast_stored(%Pgvector{} = value, _constraints), do: Pgvector.Ecto.Vector.load(value)
  def cast_stored(_value, _constraints), do: :error

  @impl true
  def dump_to_native(nil, _constraints), do: {:ok, nil}

  def dump_to_native(value, constraints) do
    with {:ok, vector} <- cast_input(value, constraints), do: Pgvector.Ecto.Vector.dump(vector)
  end
end
