defmodule Ankole.Plugins.EmailAdapter.Charset do
  @moduledoc """
  Converts mail text to UTF-8.

  UTF-8, ASCII, Latin-1, and UTF-16 use the Erlang `:unicode` module. GB2312,
  GBK, and Windows-1252 go through `codepagex`. Every other charset is
  unsupported: the caller keeps the printable ASCII bytes and records the
  charset, instead of storing bytes that are not text.
  """

  @replacement "�"

  @spec to_utf8(binary(), String.t() | nil) ::
          {:ok, String.t()} | {:error, {:unsupported_charset, String.t()}}
  def to_utf8(binary, charset) when is_binary(binary) do
    case canonical(charset) do
      :utf8 -> {:ok, scrub_utf8(binary)}
      :latin1 -> {:ok, :unicode.characters_to_binary(binary, :latin1, :utf8)}
      {:utf16, endian} -> utf16(binary, endian)
      {:codepage, encoding} -> codepage(binary, encoding, charset)
      :unsupported -> {:error, {:unsupported_charset, String.downcase(charset)}}
    end
  end

  @doc "Keeps only printable ASCII and line breaks, for text in an unsupported charset."
  @spec ascii_only(binary()) :: String.t()
  def ascii_only(binary) when is_binary(binary) do
    for <<byte <- binary>>, byte in 32..126 or byte in [?\n, ?\r, ?\t], into: "", do: <<byte>>
  end

  defp canonical(nil), do: :utf8

  defp canonical(charset) when is_binary(charset) do
    case charset |> String.trim() |> String.downcase() do
      "" -> :utf8
      "utf-8" -> :utf8
      "utf8" -> :utf8
      "us-ascii" -> :utf8
      "ascii" -> :utf8
      "iso-8859-1" -> :latin1
      "iso8859-1" -> :latin1
      "latin1" -> :latin1
      "latin-1" -> :latin1
      "utf-16" -> {:utf16, :bom}
      "utf16" -> {:utf16, :bom}
      "utf-16be" -> {:utf16, :big}
      "utf-16le" -> {:utf16, :little}
      "windows-1252" -> {:codepage, :"VENDORS/MICSFT/WINDOWS/CP1252"}
      "cp1252" -> {:codepage, :"VENDORS/MICSFT/WINDOWS/CP1252"}
      "gb2312" -> {:codepage, :"VENDORS/MICSFT/WINDOWS/CP936"}
      "gbk" -> {:codepage, :"VENDORS/MICSFT/WINDOWS/CP936"}
      "cp936" -> {:codepage, :"VENDORS/MICSFT/WINDOWS/CP936"}
      _other -> :unsupported
    end
  end

  defp utf16(<<0xFE, 0xFF, rest::binary>>, :bom), do: utf16(rest, :big)
  defp utf16(<<0xFF, 0xFE, rest::binary>>, :bom), do: utf16(rest, :little)
  defp utf16(binary, :bom), do: utf16(binary, :big)

  defp utf16(binary, endian) do
    case :unicode.characters_to_binary(binary, {:utf16, endian}, :utf8) do
      converted when is_binary(converted) -> {:ok, converted}
      _partial -> {:ok, scrub_utf8(binary)}
    end
  end

  defp codepage(binary, encoding, charset) do
    case Codepagex.to_string(binary, encoding, Codepagex.use_utf_replacement()) do
      {:ok, text, _acc} -> {:ok, text}
      {:error, _reason, _acc} -> {:error, {:unsupported_charset, String.downcase(charset)}}
    end
  end

  defp scrub_utf8(binary) do
    if String.valid?(binary) do
      binary
    else
      binary
      |> String.chunk(:valid)
      |> Enum.map_join(fn chunk -> if String.valid?(chunk), do: chunk, else: @replacement end)
    end
  end
end
