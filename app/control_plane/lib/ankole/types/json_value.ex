defmodule Ankole.Types.JsonValue do
  @moduledoc """
  Ecto type for a JSONB column whose value may be any JSON shape.

  The stock `:map` Ecto type only accepts objects. Several Ankole columns
  (signal payloads, plugin config blobs, outbox payloads) legitimately store a
  top-level array or scalar, so this type validates the *whole* JSON value tree
  instead. The validation is identical on the way in and out (`cast`, `dump`,
  and `load` all funnel through one check), so a row that fails to load loudly
  signals that something wrote a non-JSON term directly to the column.
  """

  use Ecto.Type

  # Postgres column type stays JSONB; only the Elixir-side validation differs
  # from the built-in `:map` type.
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

  # Structs are rejected even though they are maps: a `DateTime`, `Decimal`, or
  # schema struct has no faithful JSONB round-trip here, so it must be converted
  # to plain JSON terms by the caller before it reaches this column. Object keys
  # must be strings (JSON has no atom keys, and that is the form Postgres returns
  # on load), so atom-keyed maps are rejected on the way in too.
  defp json_value?(value) when is_map(value) do
    not is_struct(value) and
      Enum.all?(value, fn {key, nested} -> is_binary(key) and json_value?(nested) end)
  end

  defp json_value?(_value), do: false
end
