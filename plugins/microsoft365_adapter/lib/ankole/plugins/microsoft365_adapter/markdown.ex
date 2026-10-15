defmodule Ankole.Plugins.Microsoft365Adapter.Markdown do
  @moduledoc """
  Conservative Markdown adjustments for Teams bot messages.

  Teams renders a CommonMark subset in bot messages (`textFormat: markdown`),
  so most Markdown passes through unchanged. Only constructs Teams renders as
  literal text are rewritten into something readable: tables become plain
  lines and horizontal rules become a dashed line.
  Code spans keep the exact source bytes. These rules apply to prose.
  """

  @spec from_markdown(String.t()) :: String.t()
  def from_markdown(text) when is_binary(text) do
    Ankole.Plugins.MarkdownChunks.rewrite_prose(text, fn source, _marker ->
      source
      |> String.split("\n")
      |> Enum.map(&rewrite_line/1)
      |> Enum.join("\n")
    end)
  end

  defp rewrite_line(line) do
    trimmed = String.trim(line)

    cond do
      Regex.match?(~r/\A\|?[\s:|-]+\|[\s:|-]*\z/, trimmed) and String.contains?(trimmed, "-") ->
        ""

      String.starts_with?(trimmed, "|") and String.ends_with?(trimmed, "|") ->
        trimmed
        |> String.trim("|")
        |> String.split("|")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.join(" · ")

      trimmed in ["---", "***", "___"] ->
        "———"

      true ->
        line
    end
  end
end
