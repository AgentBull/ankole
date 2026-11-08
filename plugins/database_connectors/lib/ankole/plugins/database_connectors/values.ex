defmodule Ankole.Plugins.DatabaseConnectors.Values do
  @moduledoc """
  Converts driver values to JSON values without losing precision: decimals,
  integers beyond 2^53, and temporal values become strings; binary data that
  is not UTF-8 becomes `\\x`-prefixed hexadecimal.
  """

  @safe_integer 9_007_199_254_740_991

  def row(values) when is_list(values), do: Enum.map(values, &value/1)

  def value(nil), do: nil
  def value(value) when is_boolean(value), do: value

  def value(value) when is_integer(value) and abs(value) > @safe_integer,
    do: Integer.to_string(value)

  def value(value) when is_integer(value) or is_float(value), do: value
  def value(value) when is_atom(value), do: Atom.to_string(value)
  def value(%Decimal{} = value), do: Decimal.to_string(value, :normal)

  def value(%module{} = value) when module in [Date, Time, NaiveDateTime, DateTime],
    do: module.to_iso8601(value)

  def value(value) when is_binary(value) do
    if String.valid?(value), do: value, else: "\\x" <> Base.encode16(value, case: :lower)
  end

  def value(value) when is_list(value), do: Enum.map(value, &value/1)

  def value(%_{} = value) do
    if String.Chars.impl_for(value), do: to_string(value), else: inspect(value)
  end

  def value(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), value(v)} end)

  def value(value) when is_tuple(value), do: value |> Tuple.to_list() |> value()

  @doc "Names a JSON-safe value's type when the driver reports none."
  def kind(nil), do: nil
  def kind(value) when is_boolean(value), do: "boolean"
  def kind(value) when is_integer(value), do: "integer"
  def kind(value) when is_float(value), do: "float"
  def kind(%Decimal{}), do: "decimal"
  def kind(%Date{}), do: "date"
  def kind(%Time{}), do: "time"
  def kind(%NaiveDateTime{}), do: "datetime"
  def kind(%DateTime{}), do: "timestamp"
  def kind(value) when is_binary(value), do: if(String.valid?(value), do: "text", else: "binary")
  def kind(value) when is_map(value) or is_list(value), do: "json"
  def kind(_), do: "unknown"

  @doc "Encodes one CSV record (RFC 4180) followed by CRLF."
  def csv_line(values) do
    IO.iodata_to_binary([Enum.map_intersperse(values, ",", &csv_field/1), "\r\n"])
  end

  defp csv_field(nil), do: ""
  defp csv_field(value) when is_binary(value), do: escape(value)
  defp csv_field(value) when is_map(value) or is_list(value), do: escape(Torque.encode!(value))
  defp csv_field(value), do: escape(to_string(value))

  defp escape(text) do
    if String.contains?(text, [",", "\"", "\r", "\n"]),
      do: [?", String.replace(text, "\"", "\"\""), ?"],
      else: text
  end
end
