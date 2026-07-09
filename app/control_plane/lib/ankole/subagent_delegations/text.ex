defmodule Ankole.SubagentDelegations.Text do
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

  @spec utf8_prefix(String.t(), non_neg_integer()) :: String.t()
  def utf8_prefix(text, max_bytes) when byte_size(text) <= max_bytes, do: text

  def utf8_prefix(text, max_bytes) when is_binary(text) and max_bytes >= 0 do
    text
    |> binary_part(0, max_bytes)
    |> trim_invalid_utf8_suffix()
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
end
