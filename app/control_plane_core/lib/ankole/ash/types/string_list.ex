defmodule Ankole.Ash.Types.StringList do
  @moduledoc "A JSON array whose elements are strings."
  use Ash.Type

  @impl true
  def storage_type(_constraints), do: :map
  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}

  def cast_input(value, constraints) do
    case Ankole.Ash.Types.JSONList.cast_input(value, constraints) do
      {:ok, list} when is_list(list) ->
        if Enum.all?(list, &is_binary/1), do: {:ok, list}, else: :error

      _ ->
        :error
    end
  end

  @impl true
  def cast_atomic(value, constraints) do
    if Ash.Expr.expr?(value), do: {:atomic, value}, else: cast_input(value, constraints)
  end

  @impl true
  def cast_stored(value, constraints), do: cast_input(value, constraints)
  @impl true
  def dump_to_native(value, constraints), do: cast_input(value, constraints)
end
