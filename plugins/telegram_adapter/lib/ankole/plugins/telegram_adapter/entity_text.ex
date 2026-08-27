defmodule Ankole.Plugins.TelegramAdapter.EntityText do
  @moduledoc false

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

  @spec value(String.t(), map()) :: String.t() | nil
  def value(text, %{"offset" => offset, "length" => length}), do: slice(text, offset, length)
  def value(_text, _entity), do: nil

  @doc """
  Rebuilds the text with each `{offset, length, replacement}` segment replaced,
  in the UTF-16 code units Telegram entity offsets use. A segment that overlaps
  an earlier one or runs past the end of the text stays unreplaced. A text
  match would instead also hit equal substrings outside the entity.
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

  defp utf8_part(utf16, offset, length) do
    utf16
    |> binary_part(offset * 2, length * 2)
    |> :unicode.characters_to_binary({:utf16, :little}, :utf8)
  end
end
