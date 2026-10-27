defmodule Ankole.Pod.Position do
  @moduledoc """
  Sibling order keys. PostgreSQL compares them with `C` collation, which is
  byte order for this alphabet. A generated key never ends with the lowest
  digit, so a later key can always go before it.
  """

  @base 62
  @mid_byte ?V
  @top_byte ?z

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
    space = pow(@base, width)
    sequence_range(1, count, space, count + 1, width)
  end

  defp sequence_range(i, count, _space, _denom, _width) when i > count, do: []

  defp sequence_range(i, count, space, denom, width) do
    value = div(i * space, denom)
    key = encode(value, width, "")
    key = if rem(value, @base) == 0, do: key <> <<@mid_byte>>, else: key
    [key | sequence_range(i + 1, count, space, denom, width)]
  end

  defp width(count, current) do
    if pow(@base, current) > count, do: current, else: width(count, current + 1)
  end

  defp pow(_base, 0), do: 1
  defp pow(base, exp), do: base * pow(base, exp - 1)

  defp encode(_value, 0, acc), do: acc

  defp encode(value, width, acc) do
    digit = digit_byte(rem(value, @base))
    encode(div(value, @base), width - 1, <<digit, acc::binary>>)
  end

  defp valid?(""), do: true
  defp valid?(key), do: valid_nonempty?(key)

  defp valid_nonempty?(<<?0>>), do: false
  defp valid_nonempty?(<<c>>), do: digit_byte?(c)
  defp valid_nonempty?(<<c, rest::binary>>), do: digit_byte?(c) and valid_nonempty?(rest)
  defp valid_nonempty?(_), do: false

  defp digit_byte?(c), do: c in ?0..?9 or c in ?A..?Z or c in ?a..?z

  defp midpoint(lower, nil), do: after_key(lower)

  defp midpoint(<<c, l_rest::binary>>, <<c, u_rest::binary>>),
    do: <<c>> <> midpoint(l_rest, u_rest)

  defp midpoint("", <<?0, u_rest::binary>>),
    do: <<?0>> <> midpoint("", u_rest)

  defp midpoint(lower, <<u, u_rest::binary>>),
    do: step(lower, u, u_rest)

  # Appending raises the last digit that can rise, so a long append run adds
  # one character per alphabet pass.
  defp after_key(""), do: <<@mid_byte>>

  defp after_key(lower) do
    case raise_last(lower) do
      {:ok, raised} -> raised
      :all_top -> lower <> <<@mid_byte>>
    end
  end

  defp raise_last(<<>>), do: :all_top

  defp raise_last(<<@top_byte, rest::binary>>) do
    case raise_last(rest) do
      {:ok, raised} -> {:ok, <<@top_byte, raised::binary>>}
      :all_top -> :all_top
    end
  end

  defp raise_last(<<c, rest::binary>>) do
    case raise_last(rest) do
      {:ok, raised} -> {:ok, <<c, raised::binary>>}
      :all_top -> {:ok, <<digit_byte(digit_index(c) + 1)>>}
    end
  end

  defp step(lower, u, u_rest) do
    {low, l_rest} =
      case lower do
        "" -> {0, ""}
        <<l, rest::binary>> -> {digit_index(l), rest}
      end

    high = digit_index(u)

    cond do
      high - low > 1 -> <<digit_byte(div(low + high + 1, 2))>>
      byte_size(u_rest) > 0 -> <<u>>
      true -> <<digit_byte(low)>> <> after_key(l_rest)
    end
  end

  defp digit_index(c) when c in ?0..?9, do: c - ?0
  defp digit_index(c) when c in ?A..?Z, do: c - ?A + 10
  defp digit_index(c) when c in ?a..?z, do: c - ?a + 36

  defp digit_byte(i) when i >= 0 and i < 10, do: ?0 + i
  defp digit_byte(i) when i >= 10 and i < 36, do: ?A + i - 10
  defp digit_byte(i) when i >= 36 and i < 62, do: ?a + i - 36
end
