defmodule Discord.Mentions do
  @moduledoc false

  @behaviour BullX.EventBus.ChannelAdapter.Mentions

  alias BullX.EventBus.ChannelAdapter.Mentions

  @impl true
  def parse_mentions(%{} = message, _source) do
    entity_mentions =
      message
      |> Map.get("mentions", [])
      |> Enum.map(fn mention ->
        Mentions.mention(id: Map.get(mention, "id"), source: :entity)
      end)

    content_mentions =
      message
      |> Map.get("content", "")
      |> to_string()
      |> parse_content_mentions()

    Enum.uniq(entity_mentions ++ content_mentions)
  end

  def parse_mentions(_message, _source), do: []

  defp parse_content_mentions(content) do
    ~r/<@!?(?<id>[^>]+)>/
    |> Regex.scan(content, capture: ["id"])
    |> Enum.map(fn [id] -> Mentions.mention(id: id, source: :text) end)
  end
end
