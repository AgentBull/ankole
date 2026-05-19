defmodule Feishu.Mentions do
  @moduledoc false

  @behaviour BullX.EventBus.ChannelAdapter.Mentions

  alias BullX.EventBus.ChannelAdapter.Mentions

  @impl true
  def parse_mentions(%{"mentions" => mentions}, _source) when is_list(mentions) do
    Enum.flat_map(mentions, &mention_ids/1)
  end

  def parse_mentions(%{message: %{"mentions" => mentions}}, source) when is_list(mentions) do
    parse_mentions(%{"mentions" => mentions}, source)
  end

  def parse_mentions(%{message: message}, source) when is_map(message),
    do: parse_mentions(message, source)

  def parse_mentions(_message, _source), do: []

  defp mention_ids(%{"id" => ids} = mention) when is_map(ids) do
    [
      Mentions.mention(
        id: Map.get(ids, "open_id"),
        source: :entity,
        text: Map.get(mention, "name")
      ),
      Mentions.mention(
        id: Map.get(ids, "user_id"),
        source: :entity,
        text: Map.get(mention, "name")
      )
    ]
    |> Enum.reject(&(&1 == %{}))
  end

  defp mention_ids(_mention), do: []
end
