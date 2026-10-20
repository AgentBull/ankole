defmodule Ankole.Pod.Position do
  @moduledoc """
  Sibling order keys. PostgreSQL compares them with `C` collation, which is
  byte order for this alphabet. A generated key never ends with the lowest
  digit, so a later key can always go before it.
  """

  @digits ~c"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
  @base length(@digits)
  @index @digits |> Enum.with_index() |> Map.new()

  @doc "A key after `lower` and before `upper`. `nil` is an open end. Returns `:error` for keys it cannot order."
  def between(lower, upper) do
    lower = lower || ""

    if valid?(lower) and (is_nil(upper) or (valid?(upper) and upper != "" and lower < upper)),
      do: {:ok, midpoint(lower, upper)},
      else: :error
  end

  @doc "`count` ascending keys of one width, for a sibling list that must be renumbered."
  def sequence(count) when count > 0 do
    width = width(count + 1, 1)
    space = Integer.pow(@base, width)

    for i <- 1..count do
      key = encode(div(i * space, count + 1), width)
      if String.ends_with?(key, "0"), do: key <> "V", else: key
    end
  end

  defp width(count, width),
    do: if(Integer.pow(@base, width) > count, do: width, else: width(count, width + 1))

  defp encode(value, width) do
    value
    |> Integer.digits(@base)
    |> Enum.map(&Enum.at(@digits, &1))
    |> List.to_string()
    |> String.pad_leading(width, "0")
  end

  defp valid?(key),
    do:
      not String.ends_with?(key, "0") and
        key |> String.to_charlist() |> Enum.all?(&Map.has_key?(@index, &1))

  defp midpoint(lower, upper) when is_binary(upper) do
    case common_prefix(lower, upper, 0) do
      0 -> step(lower, upper)
      n -> binary_part(upper, 0, n) <> midpoint(tail(lower, n), tail(upper, n))
    end
  end

  # Appending raises the last digit that can rise, so a long append run adds
  # one character per alphabet pass.
  defp midpoint("", nil), do: <<Enum.at(@digits, div(@base, 2))>>

  defp midpoint(lower, nil) do
    top = List.last(@digits)

    rising =
      lower |> String.to_charlist() |> Enum.with_index() |> Enum.filter(&(elem(&1, 0) != top))

    case List.last(rising) do
      nil ->
        lower <> <<Enum.at(@digits, div(@base, 2))>>

      {char, index} ->
        binary_part(lower, 0, index) <> <<Enum.at(@digits, Map.fetch!(@index, char) + 1)>>
    end
  end

  defp step(lower, upper) do
    low = if lower == "", do: 0, else: digit(lower)
    high = if upper, do: digit(upper), else: @base

    cond do
      high - low > 1 -> <<Enum.at(@digits, div(low + high + 1, 2))>>
      is_binary(upper) and byte_size(upper) > 1 -> binary_part(upper, 0, 1)
      true -> <<Enum.at(@digits, low)>> <> midpoint(tail(lower, 1), nil)
    end
  end

  defp common_prefix(lower, upper, n) when n < byte_size(upper) do
    if char(lower, n) == :binary.at(upper, n), do: common_prefix(lower, upper, n + 1), else: n
  end

  defp common_prefix(_lower, _upper, n), do: n

  defp char(key, n) when n < byte_size(key), do: :binary.at(key, n)
  defp char(_key, _n), do: ?0

  defp digit(key), do: Map.fetch!(@index, :binary.at(key, 0))

  defp tail(key, n) when n < byte_size(key), do: binary_part(key, n, byte_size(key) - n)
  defp tail(_key, _n), do: ""
end
