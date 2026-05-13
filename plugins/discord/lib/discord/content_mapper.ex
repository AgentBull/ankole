defmodule Discord.ContentMapper do
  @moduledoc """
  Discord inbound and outbound content mapping.

  Inbound: produces Gateway content blocks (`text`, `image`, `audio`, `video`,
  `file`) preserving stable Discord identifiers through
  `discord://attachment/<channel_id>/<attachment_id>` URIs. Time-limited cdn
  URLs are not embedded.

  Outbound: renders text directly; non-text Gateway content kinds degrade to
  `body.fallback_text` (until native attachment upload is added).

  Message splitting uses UTF-16 code unit counting because Discord's 2000-unit
  limit measures code units, not codepoints or graphemes.
  """

  alias Discord.Error

  @discord_message_hard_limit 2_000
  @default_soft_limit 1_850
  @media_kinds ~w(image audio video file)
  @media_kind_atoms [:image, :audio, :video, :file]

  @spec inbound_blocks(map(), Discord.Source.t()) ::
          {:ok, [map()], String.t() | nil} | {:error, map()}
  def inbound_blocks(message, %Discord.Source{} = source) when is_map(message) do
    case primary_text_blocks(message, source) do
      {:ok, primary_block, text} ->
        attachment_blocks = attachment_blocks(message)
        sticker_blocks = sticker_blocks(message)

        blocks =
          ([primary_block] ++ attachment_blocks ++ sticker_blocks)
          |> Enum.reject(&is_nil/1)

        case blocks do
          [] -> empty_content_error()
          _other -> {:ok, blocks, text}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  def inbound_blocks(_message, _source),
    do: {:error, Error.payload("invalid Discord message payload")}

  @spec primary_text([map()]) :: String.t() | nil
  def primary_text([%{"kind" => "text", "body" => %{"text" => text}} | _rest])
      when is_binary(text),
      do: text

  def primary_text([_block | rest]), do: primary_text(rest)
  def primary_text(_other), do: nil

  @spec render_outbound(term()) :: {:ok, String.t(), [String.t()]} | {:error, map()}
  def render_outbound(nil),
    do: {:error, Error.payload("Discord delivery content is required")}

  def render_outbound([]),
    do: {:error, Error.payload("Discord delivery content is required")}

  def render_outbound([block | _rest]), do: render_outbound(block)

  def render_outbound(%{"kind" => "text", "body" => %{"text" => text}})
      when is_binary(text) and text != "" do
    {:ok, text, []}
  end

  def render_outbound(%{"kind" => kind, "body" => %{"fallback_text" => text}})
      when kind in @media_kinds and is_binary(text) and text != "" do
    {:ok, text, ["#{kind}_degraded_to_fallback_text"]}
  end

  def render_outbound(%{"kind" => "card", "body" => %{"fallback_text" => text}})
      when is_binary(text) and text != "" do
    {:ok, text, ["card_degraded_to_fallback_text"]}
  end

  def render_outbound(%{"kind" => kind})
      when kind in @media_kinds or kind == "card" do
    {:error,
     Error.unsupported("Discord #{kind} delivery requires fallback_text", %{"kind" => kind})}
  end

  def render_outbound(%{kind: kind, body: body}) when kind in @media_kind_atoms do
    render_outbound(%{"kind" => Atom.to_string(kind), "body" => stringify(body)})
  end

  def render_outbound(%{kind: :text, body: body}) do
    render_outbound(%{"kind" => "text", "body" => stringify(body)})
  end

  def render_outbound(%{kind: :card, body: body}) do
    render_outbound(%{"kind" => "card", "body" => stringify(body)})
  end

  def render_outbound(_content),
    do: {:error, Error.unsupported("unsupported Discord content")}

  @spec split_message(String.t(), pos_integer()) :: [String.t()]
  def split_message(text, limit \\ @discord_message_hard_limit)
      when is_integer(limit) and limit > 0 do
    text
    |> to_string()
    |> String.trim()
    |> case do
      "" -> [BullX.I18n.t("gateway.discord.delivery.fallback_text")]
      text -> chunk_text(text, min(limit, @discord_message_hard_limit))
    end
  end

  @spec stream_chunks(String.t(), pos_integer()) :: [String.t()]
  def stream_chunks(text, limit \\ @default_soft_limit) when is_integer(limit) and limit > 0 do
    split_message(text, min(limit, @discord_message_hard_limit))
  end

  @spec utf16_units(String.t()) :: non_neg_integer()
  def utf16_units(text) when is_binary(text) do
    for <<codepoint::utf8 <- text>>, reduce: 0 do
      count -> count + codepoint_units(codepoint)
    end
  end

  @spec strip_bot_mentions(String.t(), Discord.Source.t()) :: String.t()
  def strip_bot_mentions(text, %Discord.Source{bot_user_id: bot_user_id})
      when is_binary(text) and is_binary(bot_user_id) do
    text
    |> String.replace("<@#{bot_user_id}>", "")
    |> String.replace("<@!#{bot_user_id}>", "")
  end

  def strip_bot_mentions(text, %Discord.Source{}) when is_binary(text) do
    String.replace(text, ~r/<@!?\d+>/, "")
  end

  defp primary_text_blocks(message, %Discord.Source{} = source) do
    raw_content = field(message, :content) || ""

    case raw_content |> to_string() |> strip_bot_mentions(source) |> String.trim() do
      "" ->
        case has_media?(message) do
          true -> {:ok, nil, nil}
          false -> empty_content_error()
        end

      text ->
        {:ok, %{"kind" => "text", "body" => %{"text" => text}}, text}
    end
  end

  defp empty_content_error,
    do: {:error, Error.payload("Discord message content is empty")}

  defp has_media?(message) do
    has_attachments?(message) or has_stickers?(message) or has_embeds?(message)
  end

  defp has_attachments?(message) do
    case field(message, :attachments) do
      list when is_list(list) and list != [] -> true
      _other -> false
    end
  end

  defp has_stickers?(message) do
    case field(message, :stickers) || field(message, :sticker_items) do
      list when is_list(list) and list != [] -> true
      _other -> false
    end
  end

  defp has_embeds?(message) do
    case field(message, :embeds) do
      list when is_list(list) and list != [] -> true
      _other -> false
    end
  end

  defp attachment_blocks(message) do
    channel_id = id_string(field(message, :channel_id))

    (field(message, :attachments) || [])
    |> Enum.map(&attachment_block(&1, channel_id))
    |> Enum.reject(&is_nil/1)
  end

  defp attachment_block(attachment, channel_id) do
    attachment_id = id_string(field(attachment, :id))

    cond do
      is_nil(attachment_id) ->
        nil

      true ->
        kind = attachment_kind(attachment)

        body =
          %{
            "url" => "discord://attachment/#{channel_id}/#{attachment_id}",
            "fallback_text" => fallback_for(kind, attachment)
          }
          |> maybe_put("filename", present(field(attachment, :filename)))

        %{"kind" => Atom.to_string(kind), "body" => body}
    end
  end

  defp attachment_kind(attachment) do
    case field(attachment, :content_type) do
      "image/" <> _rest -> :image
      "audio/" <> _rest -> :audio
      "video/" <> _rest -> :video
      _other -> :file
    end
  end

  defp fallback_for(kind, attachment) do
    filename = present(field(attachment, :filename))
    filename || BullX.I18n.t("gateway.discord.media.#{kind}")
  end

  defp sticker_blocks(message) do
    stickers = field(message, :stickers) || field(message, :sticker_items) || []

    Enum.map(stickers, fn sticker ->
      name = present(field(sticker, :name)) || BullX.I18n.t("gateway.discord.media.sticker")

      %{
        "kind" => "image",
        "body" => %{
          "url" => "discord://sticker/#{id_string(field(sticker, :id))}",
          "fallback_text" => name
        }
      }
    end)
  end

  defp chunk_text(text, limit) do
    text
    |> codepoints()
    |> Enum.reduce({[], [], 0}, fn {binary, units}, {chunks, current, current_units} ->
      cond do
        current_units + units > limit and current != [] ->
          {[Enum.reverse(current) | chunks], [binary], units}

        true ->
          {chunks, [binary | current], current_units + units}
      end
    end)
    |> case do
      {chunks, [], _units} -> Enum.reverse(chunks)
      {chunks, current, _units} -> Enum.reverse([Enum.reverse(current) | chunks])
    end
    |> Enum.map(&IO.iodata_to_binary/1)
  end

  defp codepoints(text) do
    for <<codepoint::utf8 <- text>> do
      {<<codepoint::utf8>>, codepoint_units(codepoint)}
    end
  end

  defp codepoint_units(codepoint) when codepoint > 0xFFFF, do: 2
  defp codepoint_units(_codepoint), do: 1

  defp stringify(%{} = body) do
    Map.new(body, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  defp stringify(body), do: body

  defp field(%{} = map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(_value, _key), do: nil

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  defp id_string(nil), do: nil
  defp id_string(value) when is_binary(value) and value != "", do: value
  defp id_string(value) when is_integer(value), do: Integer.to_string(value)
  defp id_string(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
