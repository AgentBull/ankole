defmodule Ankole.SignalsGateway.AIReplyText do
  @moduledoc false

  # Provider server-side search (for example the ChatGPT backend) wraps inline
  # citation tokens in Private Use Area delimiters: U+E200 opens, U+E202
  # separates, U+E201 closes, as in `\x{E200}cite\x{E202}turn0search0\x{E201}`.
  # These never render in a chat client and must never reach a channel.
  @citation_span ~r/\x{E200}.*?\x{E201}/su

  def visible_text(items) when is_list(items) do
    items
    |> Enum.flat_map(&visible_text_parts/1)
    |> Enum.join("")
    |> normalize_visible_text()
    |> case do
      "" -> nil
      text -> text
    end
  end

  def visible_text(_items), do: nil

  def normalize_visible_text(text) when is_binary(text) do
    text
    |> String.replace(@citation_span, "")
    |> String.trim()
  end

  def normalize_visible_text(_text), do: ""

  defp visible_text_parts(%{"type" => "message", "role" => role, "content" => content})
       when role in ["assistant", nil] and is_list(content),
       do: Enum.flat_map(content, &visible_text_parts/1)

  defp visible_text_parts(%{"type" => "message", "role" => role, "content" => text})
       when role in ["assistant", nil] and is_binary(text),
       do: [text]

  defp visible_text_parts(%{"type" => "message", "role" => _role}), do: []

  defp visible_text_parts(%{"type" => "message", "content" => content}) when is_list(content),
    do: Enum.flat_map(content, &visible_text_parts/1)

  defp visible_text_parts(%{"type" => "message", "content" => text}) when is_binary(text),
    do: [text]

  defp visible_text_parts(%{"type" => type, "text" => text})
       when type in ["output_text", "text"] and is_binary(text),
       do: [text]

  defp visible_text_parts(_item), do: []
end
