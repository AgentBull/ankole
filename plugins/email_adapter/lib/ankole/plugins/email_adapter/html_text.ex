defmodule Ankole.Plugins.EmailAdapter.HtmlText do
  @moduledoc "Converts an HTML mail body to plain text and keeps link targets."

  @entities %{
    "amp" => "&",
    "lt" => "<",
    "gt" => ">",
    "quot" => "\"",
    "apos" => "'",
    "nbsp" => " ",
    "copy" => "©",
    "reg" => "®",
    "hellip" => "…",
    "mdash" => "—",
    "ndash" => "–",
    "lsquo" => "‘",
    "rsquo" => "’",
    "ldquo" => "“",
    "rdquo" => "”"
  }

  @spec to_text(String.t()) :: String.t()
  def to_text(html) when is_binary(html) do
    html
    |> String.replace(~r/<!--.*?-->/s, "")
    |> String.replace(~r/<(script|style|head|title)\b[^>]*>.*?<\/\1\s*>/is, "")
    |> String.replace(~r/<a\b[^>]*href\s*=\s*["']?([^"'\s>]+)["']?[^>]*>(.*?)<\/a\s*>/is, &link/1)
    |> String.replace(~r/<br\s*\/?>/i, "\n")
    |> String.replace(~r/<\/(p|div|li|tr|h[1-6]|blockquote|pre|table|section|article)\s*>/i, "\n")
    |> String.replace(~r/<(hr)\b[^>]*\/?>/i, "\n----\n")
    |> String.replace(~r/<li\b[^>]*>/i, "- ")
    |> String.replace(~r/<[^>]+>/, "")
    |> decode_entities()
    |> String.split(~r/\r?\n/)
    |> Enum.map(&(&1 |> String.replace(~r/[ \t\x{00A0}]+/u, " ") |> String.trim()))
    |> Enum.join("\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp link(match) do
    case Regex.run(~r/href\s*=\s*["']?([^"'\s>]+)["']?[^>]*>(.*?)<\/a\s*>/is, match) do
      [_all, href, inner] ->
        text = inner |> String.replace(~r/<[^>]+>/, "") |> String.trim()

        cond do
          text == "" -> href
          String.contains?(href, text) -> text
          String.starts_with?(href, ["mailto:", "javascript:"]) -> text
          true -> "#{text} (#{href})"
        end

      nil ->
        ""
    end
  end

  defp decode_entities(text) do
    Regex.replace(~r/&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z]+);/, text, fn all, entity ->
      case entity do
        "#x" <> hex -> codepoint(String.to_integer(hex, 16), all)
        "#" <> decimal -> codepoint(String.to_integer(decimal), all)
        name -> Map.get(@entities, name, all)
      end
    end)
  end

  defp codepoint(value, all) do
    if value in 1..0x10FFFF and value not in 0xD800..0xDFFF, do: <<value::utf8>>, else: all
  rescue
    _exception -> all
  end
end
