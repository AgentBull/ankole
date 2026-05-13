defmodule BullX.Gateway.JSON do
  @moduledoc false

  @spec json_object?(term()) :: boolean()
  def json_object?(%{} = value) do
    Enum.all?(value, fn
      {key, nested} when is_binary(key) -> json_neutral?(nested)
      _other -> false
    end)
  end

  def json_object?(_value), do: false

  @spec json_neutral?(term()) :: boolean()
  def json_neutral?(value) when is_binary(value) or is_boolean(value) or is_nil(value), do: true
  def json_neutral?(value) when is_integer(value), do: true
  def json_neutral?(value) when is_float(value), do: finite_float?(value)
  def json_neutral?([_ | _] = values), do: Enum.all?(values, &json_neutral?/1)
  def json_neutral?([]), do: true
  def json_neutral?(%{} = value), do: json_object?(value)
  def json_neutral?(_value), do: false

  @spec stringify_keys(term()) :: {:ok, term()} | :error
  def stringify_keys(%{} = map) do
    Enum.reduce_while(map, {:ok, %{}}, fn
      {key, value}, {:ok, acc} when is_binary(key) ->
        case stringify_keys(value) do
          {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
          :error -> {:halt, :error}
        end

      {key, value}, {:ok, acc} when is_atom(key) ->
        case stringify_keys(value) do
          {:ok, value} -> {:cont, {:ok, Map.put(acc, Atom.to_string(key), value)}}
          :error -> {:halt, :error}
        end

      {_key, _value}, _acc ->
        {:halt, :error}
    end)
  end

  def stringify_keys([_ | _] = values) do
    values
    |> Enum.map(&stringify_keys/1)
    |> collect_values()
  end

  def stringify_keys([]), do: {:ok, []}

  def stringify_keys(value)
      when is_binary(value) or is_boolean(value) or is_integer(value) or is_float(value) or
             is_nil(value) do
    case json_neutral?(value) do
      true -> {:ok, value}
      false -> :error
    end
  end

  def stringify_keys(_value), do: :error

  defp collect_values(values) do
    case Enum.all?(values, &match?({:ok, _value}, &1)) do
      true -> {:ok, Enum.map(values, fn {:ok, value} -> value end)}
      false -> :error
    end
  end

  defp finite_float?(value), do: value == value and value not in [:infinity, :neg_infinity]
end
