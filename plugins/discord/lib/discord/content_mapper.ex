defmodule Discord.ContentMapper do
  @moduledoc false

  @message_limit 2_000

  @spec from_message(map(), Discord.Source.t()) :: {:ok, [map()]} | {:error, map()}
  def from_message(%{} = message, %Discord.Source{} = source) do
    text =
      message
      |> Map.get("content")
      |> strip_bot_mentions(source.bot_user_id)

    blocks =
      []
      |> maybe_add_text(text)
      |> add_attachments(Map.get(message, "attachments", []), Map.get(message, "channel_id"))
      |> add_embeds(Map.get(message, "embeds", []))
      |> add_stickers(Map.get(message, "sticker_items", []))
      |> case do
        [] -> [text_block(BullX.I18n.t("eventbus.discord.errors.unsupported_message"))]
        blocks -> Enum.reverse(blocks)
      end

    {:ok, blocks}
  end

  def from_message(_message, _source),
    do: {:error, Discord.Error.payload("invalid Discord message")}

  defdelegate primary_text(blocks), to: BullX.EventBus.ChannelAdapter.Content

  @spec render_outbound(term()) :: {:ok, [String.t()], [String.t()]} | {:error, map()}
  def render_outbound([%{"type" => "text", "text" => text} | _rest])
      when is_binary(text) and text != "" do
    {:ok, split_text(text, @message_limit), []}
  end

  def render_outbound([%{"kind" => "text", "body" => %{"text" => text}} | _rest])
      when is_binary(text) and text != "" do
    {:ok, split_text(text, @message_limit), []}
  end

  def render_outbound(%{"type" => "text", "text" => text}) when is_binary(text) and text != "" do
    {:ok, split_text(text, @message_limit), []}
  end

  def render_outbound(%{"kind" => "text", "body" => %{"text" => text}})
      when is_binary(text) and text != "" do
    {:ok, split_text(text, @message_limit), []}
  end

  def render_outbound(%{kind: "text", body: %{text: text}}),
    do: render_outbound(%{"kind" => "text", "body" => %{"text" => text}})

  def render_outbound([%{"type" => type} = block | _rest]), do: render_fallback(type, block)
  def render_outbound(%{"type" => type} = block), do: render_fallback(type, block)

  def render_outbound([%{"kind" => kind, "body" => body} | _rest]),
    do: render_fallback(kind, body)

  def render_outbound(%{"kind" => kind, "body" => body}), do: render_fallback(kind, body)

  def render_outbound(_content),
    do: {:error, Discord.Error.payload("Discord delivery content is required")}

  defdelegate utf16_units(text), to: BullX.Utils.Text
  defdelegate split_text(text, limit), to: BullX.Utils.Text

  @spec strip_bot_mentions(String.t() | nil, String.t() | nil) :: String.t()
  def strip_bot_mentions(text, bot_user_id) when is_binary(text) and is_binary(bot_user_id) do
    text
    |> String.replace(~r/<@!?#{Regex.escape(bot_user_id)}>/, "")
    |> String.trim()
  end

  def strip_bot_mentions(text, _bot_user_id) when is_binary(text), do: String.trim(text)
  def strip_bot_mentions(_text, _bot_user_id), do: ""

  defp maybe_add_text(blocks, ""), do: blocks
  defp maybe_add_text(blocks, text) when is_binary(text), do: [text_block(text) | blocks]
  defp text_block(text), do: %{"type" => "text", "text" => text}

  defp add_attachments(blocks, attachments, channel_id) when is_list(attachments) do
    Enum.reduce(attachments, blocks, fn attachment, acc ->
      case Map.get(attachment, "id") do
        id when is_binary(id) ->
          kind = attachment_kind(attachment)

          [
            media_block(kind, "discord://attachment/#{channel_id || "unknown"}/#{id}", attachment)
            | acc
          ]

        _value ->
          acc
      end
    end)
  end

  defp add_attachments(blocks, _attachments, _channel_id), do: blocks

  defp add_embeds(blocks, embeds) when is_list(embeds) do
    Enum.reduce(embeds, blocks, fn embed, acc ->
      text =
        [Map.get(embed, "title"), Map.get(embed, "description")]
        |> Enum.filter(&(is_binary(&1) and &1 != ""))
        |> Enum.join("\n")

      maybe_add_text(acc, text)
    end)
  end

  defp add_embeds(blocks, _embeds), do: blocks

  defp add_stickers(blocks, stickers) when is_list(stickers) do
    Enum.reduce(stickers, blocks, fn sticker, acc ->
      case Map.get(sticker, "id") do
        id when is_binary(id) -> [media_block("image", "discord://sticker/#{id}", sticker) | acc]
        _value -> maybe_add_text(acc, BullX.I18n.t("eventbus.discord.media.sticker"))
      end
    end)
  end

  defp add_stickers(blocks, _stickers), do: blocks

  defp attachment_kind(%{"content_type" => "image/" <> _rest}), do: "image"
  defp attachment_kind(%{"content_type" => "audio/" <> _rest}), do: "audio"
  defp attachment_kind(%{"content_type" => "video/" <> _rest}), do: "video"
  defp attachment_kind(_attachment), do: "file"

  defp media_block(kind, url, attachment) do
    %{
      "type" => normalized_media_type(kind),
      "url" => url,
      "fallback_text" => fallback_text(kind, attachment)
    }
    |> maybe_put_media_type(attachment)
  end

  defp maybe_put_media_type(block, %{"content_type" => media_type}) when is_binary(media_type) do
    case String.trim(media_type) do
      "" -> block
      value -> Map.put(block, "media_type", value)
    end
  end

  defp maybe_put_media_type(block, _attachment), do: block

  defp fallback_text(kind, %{"filename" => filename}) when is_binary(filename) do
    case String.trim(filename) do
      "" -> "[#{kind}]"
      value -> value
    end
  end

  defp fallback_text(kind, _attachment), do: "[#{kind}]"

  defp normalized_media_type("image"), do: "image_url"
  defp normalized_media_type("video"), do: "video_url"
  defp normalized_media_type(_kind), do: "file"

  defp render_fallback(kind, body) do
    text =
      case get_in(body, ["fallback_text"]) do
        value when is_binary(value) and value != "" -> value
        _value -> BullX.I18n.t("eventbus.discord.delivery.fallback_text")
      end

    {:ok, [text], ["#{kind}_degraded_to_fallback_text"]}
  end
end
