defmodule BullxTelegram.Mentions do
  @moduledoc false

  @behaviour BullX.EventBus.ChannelAdapter.Mentions

  alias BullX.EventBus.ChannelAdapter.Mentions

  @impl true
  def parse_mentions(%{} = message, _source) do
    text = Map.get(message, "text") || Map.get(message, "caption") || ""
    entities = Map.get(message, "entities") || Map.get(message, "caption_entities") || []

    entity_mentions = Enum.flat_map(entities, &mention_from_entity(text, &1))

    case entity_mentions do
      [] -> Mentions.extract_username_tokens(text)
      mentions -> mentions
    end
  end

  def parse_mentions(_message, _source), do: []

  defp mention_from_entity(text, %{"type" => "mention", "offset" => offset, "length" => length}) do
    username =
      text
      |> Mentions.slice_text(offset, length)
      |> case do
        nil -> nil
        value -> String.trim_leading(value, "@")
      end

    [Mentions.mention(username: username, source: :entity)]
  end

  defp mention_from_entity(_text, %{"type" => "text_mention", "user" => %{"id" => id}}) do
    [Mentions.mention(id: id, source: :entity)]
  end

  defp mention_from_entity(_text, _entity), do: []
end
