defmodule Ankole.Plugins.UTF16Text do
  @moduledoc """
  Text helpers for providers that count UTF-16 code units.

  Telegram entity offsets, LINE mention indexes, and the message limits of
  Telegram, Discord, and LINE all count UTF-16 code units, so a supplementary
  character such as an emoji counts as two.
  """

  @spec units(String.t()) :: non_neg_integer()
  def units(text) when is_binary(text) do
    Enum.reduce(String.to_charlist(text), 0, fn codepoint, units ->
      units + if(codepoint > 0xFFFF, do: 2, else: 1)
    end)
  end

  @spec slice(String.t(), non_neg_integer(), non_neg_integer()) :: String.t() | nil
  def slice(text, offset, length)
      when is_binary(text) and is_integer(offset) and offset >= 0 and is_integer(length) and
             length >= 0 do
    utf16 = :unicode.characters_to_binary(text, :utf8, {:utf16, :little})
    start = offset * 2
    bytes = length * 2

    if start + bytes <= byte_size(utf16) do
      utf16
      |> binary_part(start, bytes)
      |> :unicode.characters_to_binary({:utf16, :little}, :utf8)
    end
  rescue
    _exception -> nil
  end

  def slice(_text, _offset, _length), do: nil

  @doc """
  Rebuilds the text with each `{offset, length, replacement}` segment replaced,
  in UTF-16 code units. A segment that overlaps an earlier one or runs past the
  end of the text stays unreplaced. A text match would instead also hit equal
  substrings outside the segment.
  """
  @spec splice(String.t(), [{non_neg_integer(), non_neg_integer(), String.t()}]) :: String.t()
  def splice(text, segments) when is_binary(text) and is_list(segments) do
    utf16 = :unicode.characters_to_binary(text, :utf8, {:utf16, :little})
    total = div(byte_size(utf16), 2)

    {parts, cursor} =
      segments
      |> Enum.sort()
      |> Enum.reduce({[], 0}, fn {offset, length, replacement}, {parts, cursor} ->
        if is_integer(offset) and is_integer(length) and offset >= cursor and
             length >= 0 and offset + length <= total do
          {[replacement, utf8_part(utf16, cursor, offset - cursor) | parts], offset + length}
        else
          {parts, cursor}
        end
      end)

    [utf8_part(utf16, cursor, total - cursor) | parts]
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  rescue
    _exception -> text
  end

  @doc """
  Splits text into chunks of at most `limit` UTF-16 code units without
  splitting a grapheme. A grapheme longer than the limit splits between code
  points. Empty text gives no chunks.
  """
  @spec chunks(String.t(), pos_integer()) :: [String.t()]
  def chunks(text, limit) when is_binary(text) and is_integer(limit) and limit > 0 do
    {chunks, current, _units} =
      text
      |> String.graphemes()
      |> Enum.flat_map(fn grapheme ->
        if units(grapheme) > limit, do: String.codepoints(grapheme), else: [grapheme]
      end)
      |> Enum.reduce({[], [], 0}, fn segment, {chunks, current, units} ->
        segment_units = units(segment)

        if units + segment_units <= limit do
          {chunks, [segment | current], units + segment_units}
        else
          {[Enum.join(Enum.reverse(current)) | chunks], [segment], segment_units}
        end
      end)

    chunks =
      case current do
        [] -> chunks
        current -> [Enum.join(Enum.reverse(current)) | chunks]
      end

    Enum.reverse(chunks)
  end

  defp utf8_part(utf16, offset, length) do
    utf16
    |> binary_part(offset * 2, length * 2)
    |> :unicode.characters_to_binary({:utf16, :little}, :utf8)
  end
end
