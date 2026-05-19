defmodule BullX.EventBus.ChannelAdapter.Content do
  @moduledoc """
  Helpers over BullX channel-adapter content blocks.

  Adapters normalize provider messages into a list of content blocks. Text-like
  blocks may use one of these shapes:

    * `%{"type" => "text", "text" => binary()}` — flat
    * `%{"kind" => "text", "body" => %{"text" => binary()}}` — nested
    * `%{"kind" => "control_notice", "body" => %{"text" => binary()}}` —
      outbound-only tooltip-like control feedback
    * `%{"kind" => "progress_notice", "body" => %{"text" => binary()}}` —
      outbound-only updateable progress feedback

  `primary_text/1` returns the first text payload found regardless of which
  shape it carries, or `nil` if the list contains no text block.
  """

  @spec primary_text([map()]) :: String.t() | nil
  def primary_text([%{"type" => "text", "text" => text} | _rest]) when is_binary(text), do: text

  def primary_text([%{"kind" => "text", "body" => %{"text" => text}} | _rest])
      when is_binary(text),
      do: text

  def primary_text([_block | rest]), do: primary_text(rest)
  def primary_text([]), do: nil

  @spec delivery_text(map()) :: String.t() | nil
  def delivery_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text

  def delivery_text(%{"kind" => "text", "body" => %{"text" => text}}) when is_binary(text),
    do: text

  def delivery_text(%{"type" => "control_notice"} = block), do: first_present(block)

  def delivery_text(%{"kind" => "control_notice", "body" => body}) when is_map(body),
    do: first_present(body)

  def delivery_text(%{kind: "control_notice", body: body}) when is_map(body),
    do: first_present(body)

  def delivery_text(%{"type" => "progress_notice"} = block), do: first_present(block)

  def delivery_text(%{"kind" => "progress_notice", "body" => body}) when is_map(body),
    do: first_present(body)

  def delivery_text(%{kind: "progress_notice", body: body}) when is_map(body),
    do: first_present(body)

  def delivery_text(_block), do: nil

  defp first_present(map) do
    Enum.find_value(["text", "short_text", "fallback_text"], fn key ->
      case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
        value when is_binary(value) and value != "" -> value
        _value -> nil
      end
    end)
  end
end
