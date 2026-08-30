defmodule Ankole.SignalsGateway.AIReplyText do
  @moduledoc false

  @silent_success_marker "<silent_success/>"

  # Provider server-side search (for example the ChatGPT backend) wraps inline
  # citation tokens in Private Use Area delimiters: U+E200 opens, U+E202
  # separates, U+E201 closes, as in `\x{E200}cite\x{E202}turn0search0\x{E201}`.
  # These never render in a chat client and must never reach a channel.
  @citation_span ~r/\x{E200}.*?\x{E201}/su

  def silent_success_marker, do: @silent_success_marker

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

  # The single normalizer for every channel-visible projection: the final reply
  # text, the streaming preview, and the outbox tail all pass through here. It
  # strips control and citation markers unconditionally so a stray sentinel or a
  # provider citation token can never leak to a channel, even on a turn that did
  # not permit silent success. An all-marker reply collapses to "", which the
  # user-visible-projection contract then rejects as an empty completion.
  def normalize_visible_text(text) when is_binary(text) do
    text
    |> String.replace(@citation_span, "")
    |> String.replace(@silent_success_marker, "")
    |> String.trim()
  end

  def normalize_visible_text(_text), do: ""

  def silent_success_marker_prefix?(text) when is_binary(text) do
    candidate = String.trim_leading(text)

    candidate == "" or String.starts_with?(@silent_success_marker, candidate) or
      String.trim(text) == @silent_success_marker
  end

  def silent_success_marker_prefix?(_text), do: false

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
