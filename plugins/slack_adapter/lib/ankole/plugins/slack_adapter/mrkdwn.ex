defmodule Ankole.Plugins.SlackAdapter.Mrkdwn do
  @moduledoc false

  @spec from_markdown(String.t()) :: String.t()
  def from_markdown(markdown) when is_binary(markdown) do
    markdown
    |> protect_code()
    |> transform_inline()
    |> transform_lines()
    |> restore_code()
  end

  defp protect_code(text) do
    {text, blocks} = protect(text, ~r/```[\s\S]*?```/, "BLOCK")
    {text, tables} = protect_tables(text, length(blocks))
    {text, inline} = protect(text, ~r/`[^`\n]+`/, "INLINE")
    {text, blocks ++ tables, inline}
  end

  defp protect_tables(text, offset) do
    matches = Regex.scan(~r/(?:^\s*\|.*(?:\n|$))+/m, text) |> List.flatten()

    replaced =
      matches
      |> Enum.with_index()
      |> Enum.reduce(text, fn {match, index}, acc ->
        trailing_newline = if String.ends_with?(match, "\n"), do: "\n", else: ""

        String.replace(
          acc,
          match,
          "\u0000BLOCK:#{index + offset}\u0000" <> trailing_newline,
          global: false
        )
      end)

    wrapped = Enum.map(matches, &("```\n" <> String.trim_trailing(&1) <> "\n```"))
    {replaced, wrapped}
  end

  defp protect(text, regex, kind) do
    matches = Regex.scan(regex, text) |> List.flatten()

    replaced =
      matches
      |> Enum.with_index()
      |> Enum.reduce(text, fn {match, index}, acc ->
        String.replace(acc, match, "\u0000#{kind}:#{index}\u0000", global: false)
      end)

    {replaced, matches}
  end

  defp transform_lines({text, blocks, inline}) do
    lines = String.split(text, "\n")

    transformed = lines |> Enum.map(&transform_line/1) |> Enum.join("\n")

    {transformed, blocks, inline}
  end

  defp transform_line(line) do
    cond do
      Regex.match?(~r/^\s*\#{1,6}\s+/, line) ->
        title = Regex.replace(~r/^\s*\#{1,6}\s+/, line, "")
        "*#{title}*"

      Regex.match?(~r/^\s*[-*]\s+/, line) ->
        Regex.replace(~r/^(\s*)[-*]\s+/, line, "\\1• ")

      true ->
        line
    end
  end

  defp transform_inline({text, blocks, inline}) do
    text =
      text
      |> then(&Regex.replace(~r/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/, &1, "<\\2|\\1>"))
      |> then(&Regex.replace(~r/(?<!\*)\*([^*\n]+)\*(?!\*)/, &1, "_\\1_"))
      |> then(&Regex.replace(~r/\*\*([^*]+)\*\*/, &1, "*\\1*"))
      |> then(&Regex.replace(~r/__([^_]+)__/, &1, "*\\1*"))
      |> then(&Regex.replace(~r/~~([^~]+)~~/, &1, "~\\1~"))

    {text, blocks, inline}
  end

  defp restore_code({text, blocks, inline}) do
    text = restore(text, inline, "INLINE")
    restore(text, blocks, "BLOCK")
  end

  defp restore(text, matches, kind) do
    matches
    |> Enum.with_index()
    |> Enum.reduce(text, fn {match, index}, acc ->
      String.replace(acc, "\u0000#{kind}:#{index}\u0000", match)
    end)
  end
end
