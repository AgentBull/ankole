defmodule Ankole.Text do
  @moduledoc false

  @spec truncate_utf8(String.t(), non_neg_integer(), String.t()) :: String.t()
  def truncate_utf8(text, max_bytes, suffix \\ "")
      when is_binary(text) and is_integer(max_bytes) and max_bytes >= 0 and is_binary(suffix) do
    if byte_size(text) <= max_bytes do
      text
    else
      available = max(max_bytes - byte_size(suffix), 0)
      utf8_prefix(text, available) <> suffix
    end
  end

  @spec truncate_utf8_window(String.t(), non_neg_integer(), String.t()) :: String.t()
  def truncate_utf8_window(text, max_bytes, marker \\ "...[truncated]...")
      when is_binary(text) and is_integer(max_bytes) and max_bytes >= 0 and is_binary(marker) do
    if byte_size(text) <= max_bytes do
      text
    else
      marker = utf8_prefix(marker, max_bytes)
      available = max_bytes - byte_size(marker)
      head_bytes = div(available + 1, 2)
      tail_bytes = available - head_bytes
      utf8_prefix(text, head_bytes) <> marker <> utf8_suffix(text, tail_bytes)
    end
  end

  @spec utf8_prefix(binary(), non_neg_integer()) :: String.t()
  def utf8_prefix(text, max_bytes)
      when is_binary(text) and is_integer(max_bytes) and max_bytes >= 0 do
    text
    |> binary_part(0, min(byte_size(text), max_bytes))
    |> trim_invalid_utf8_suffix()
  end

  @spec utf8_suffix(String.t(), non_neg_integer()) :: String.t()
  def utf8_suffix(text, max_bytes) when byte_size(text) <= max_bytes, do: text
  def utf8_suffix(_text, 0), do: ""

  def utf8_suffix(text, max_bytes) when is_binary(text) and max_bytes > 0 do
    text
    |> binary_part(byte_size(text) - max_bytes, max_bytes)
    |> trim_invalid_utf8_prefix()
  end

  defp trim_invalid_utf8_prefix(<<>>), do: ""

  defp trim_invalid_utf8_prefix(text) do
    if String.valid?(text) do
      text
    else
      text
      |> binary_part(1, byte_size(text) - 1)
      |> trim_invalid_utf8_prefix()
    end
  end

  defp trim_invalid_utf8_suffix(<<>>), do: ""

  defp trim_invalid_utf8_suffix(text) do
    if String.valid?(text) do
      text
    else
      text
      |> binary_part(0, byte_size(text) - 1)
      |> trim_invalid_utf8_suffix()
    end
  end

  @spec chunk_graphemes(String.t(), pos_integer()) :: [String.t()]
  def chunk_graphemes("", limit) when is_integer(limit) and limit > 0, do: [""]

  def chunk_graphemes(text, limit) when is_integer(limit) and limit > 0 do
    text |> String.graphemes() |> Enum.chunk_every(limit) |> Enum.map(&Enum.join/1)
  end

  @spec grapheme_prefix(String.t(), non_neg_integer()) :: String.t()
  def grapheme_prefix(text, max_bytes), do: take_graphemes(text, max_bytes, [])

  defp take_graphemes(_text, 0, parts),
    do: parts |> Enum.reverse() |> IO.iodata_to_binary()

  defp take_graphemes(text, remaining, parts) do
    case String.next_grapheme(text) do
      {grapheme, rest} when byte_size(grapheme) <= remaining ->
        take_graphemes(rest, remaining - byte_size(grapheme), [grapheme | parts])

      _ ->
        parts |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  @spec utf16_length(String.t()) :: non_neg_integer()
  def utf16_length(text),
    do:
      Enum.reduce(String.to_charlist(text), 0, fn c, n -> n + if(c > 0xFFFF, do: 2, else: 1) end)

  @spec utf16_prefix(String.t(), non_neg_integer()) :: String.t()
  def utf16_prefix(text, max) do
    {chars, _} =
      Enum.reduce_while(String.to_charlist(text), {[], 0}, fn c, {chars, count} ->
        size = if c > 0xFFFF, do: 2, else: 1

        if count + size > max,
          do: {:halt, {chars, count}},
          else: {:cont, {[c | chars], count + size}}
      end)

    chars |> Enum.reverse() |> List.to_string()
  end

  @spec utf16_slice(String.t(), non_neg_integer(), non_neg_integer()) :: String.t()
  def utf16_slice(text, offset, length) do
    text
    |> :unicode.characters_to_binary(:utf8, {:utf16, :little})
    |> binary_part(offset * 2, length * 2)
    |> decode_utf16()
  end

  defp decode_utf16(units) do
    case :unicode.characters_to_binary(units, {:utf16, :little}, :utf8) do
      text when is_binary(text) -> text
      {_error, prefix, <<_surrogate::16, rest::binary>>} -> prefix <> "�" <> decode_utf16(rest)
    end
  end
end
