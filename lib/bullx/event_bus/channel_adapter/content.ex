defmodule BullX.EventBus.ChannelAdapter.Content do
  @moduledoc """
  Helpers over BullX channel-adapter content blocks.

  Adapters normalize provider messages into a list of content blocks of one of
  two shapes:

    * `%{"type" => "text", "text" => binary()}` — flat
    * `%{"kind" => "text", "body" => %{"text" => binary()}}` — nested

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
end
