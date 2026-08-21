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
end
