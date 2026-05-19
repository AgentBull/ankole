defmodule BullX.Utils.Text do
  @moduledoc """
  Text length and chunking utilities.

  `utf16_units/1` and `split_text/2` are extracted from the Telegram and Discord
  ContentMappers, which both count message length in UTF-16 code units (the
  unit Telegram's `entities[].offset/length` use and Discord effectively
  matches). Other adapters that count differently (characters, bytes) should
  not use these directly — write a dedicated counter and splitter.
  """

  @spec utf16_units(String.t()) :: non_neg_integer()
  def utf16_units(text) when is_binary(text) do
    text
    |> String.to_charlist()
    |> Enum.reduce(0, fn codepoint, acc -> acc + if(codepoint > 0xFFFF, do: 2, else: 1) end)
  end

  @spec split_text(String.t(), pos_integer()) :: [String.t()]
  def split_text(text, limit) when is_binary(text) and is_integer(limit) and limit > 0 do
    {chunks, current, _units} =
      text
      |> String.to_charlist()
      |> Enum.reduce({[], [], 0}, fn codepoint, {chunks, current, units} ->
        code_units = if codepoint > 0xFFFF, do: 2, else: 1

        case units + code_units > limit and current != [] do
          true ->
            {[current |> Enum.reverse() |> List.to_string() | chunks], [codepoint], code_units}

          false ->
            {chunks, [codepoint | current], units + code_units}
        end
      end)

    [current |> Enum.reverse() |> List.to_string() | chunks]
    |> Enum.reject(&(&1 == ""))
    |> Enum.reverse()
  end
end
