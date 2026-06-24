defmodule Ankole.Types.JsonValue do
  @moduledoc """
  Ecto type for JSONB values that may be objects, arrays, or scalars.
  """

  use Ecto.Type

  def type, do: :map

  def cast(value), do: cast_json(value)
  def dump(value), do: cast_json(value)
  def load(value), do: cast_json(value)

  def embed_as(_format), do: :self
  def equal?(left, right), do: left == right

  defp cast_json(value) do
    case json_value?(value) do
      true -> {:ok, value}
      false -> :error
    end
  end

  defp json_value?(nil), do: true
  defp json_value?(value) when is_boolean(value), do: true
  defp json_value?(value) when is_binary(value), do: true
  defp json_value?(value) when is_integer(value), do: true
  defp json_value?(value) when is_float(value), do: true
  defp json_value?(values) when is_list(values), do: Enum.all?(values, &json_value?/1)

  defp json_value?(value) when is_map(value) do
    not is_struct(value) and
      Enum.all?(value, fn {key, nested} -> is_binary(key) and json_value?(nested) end)
  end

  defp json_value?(_value), do: false
end
