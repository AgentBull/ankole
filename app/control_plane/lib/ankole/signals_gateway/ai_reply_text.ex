defmodule Ankole.SignalsGateway.AIReplyText do
  @moduledoc false

  alias Ankole.Actors.ActorEvent

  @silent_success_marker "<silent_success/>"

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

  def normalize_visible_text(text) when is_binary(text) do
    case String.trim(text) do
      "" -> ""
      @silent_success_marker -> ""
      text -> text
    end
  end

  def normalize_visible_text(_text), do: ""

  def silent_success_allowed?(%ActorEvent{type: "check_back_later.wakeup"}), do: true

  def silent_success_allowed?(%ActorEvent{type: "cron.fire", payload: payload}) do
    data = map_value(payload, "data") || %{}
    wake_payload = map_value(data, "wake_payload") || %{}
    delivery = map_value(wake_payload, "delivery") || %{}

    map_value(wake_payload, "quiet_success") == true or
      map_value(delivery, "quiet_success") == true
  end

  def silent_success_allowed?(%ActorEvent{}), do: false

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

  defp map_value(map, key) when is_map(map), do: Map.get(map, key)
  defp map_value(_map, _key), do: nil
end
