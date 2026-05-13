defmodule BullxTelegram.ContentMapper do
  @moduledoc """
  Telegram inbound payload and outbound content mapping.

  Inbound: produces Gateway content blocks (`text`, `image`, `audio`, `video`,
  `file`) preserving native media references through `telegram://file/<file_id>`
  URIs. Outbound: renders text directly; non-text Gateway content kinds
  degrade to `body.fallback_text` until native media upload is added.

  UTF-16 splitting is required because Telegram measures message length in
  UTF-16 code units, not codepoints or graphemes. Multi-byte (BMP) codepoints
  count as 1 unit; supplementary-plane codepoints (above 0xFFFF) count as 2.
  """

  alias BullxTelegram.Error

  @telegram_message_limit 4_096
  @default_soft_limit 3_900
  @media_kinds ~w(image audio video file)
  @media_kind_atoms [:image, :audio, :video, :file]

  @spec inbound_blocks(map()) :: {:ok, [map()]} | {:error, map()}
  def inbound_blocks(message) when is_map(message) do
    cond do
      present_binary?(field(message, :text)) ->
        {:ok, [text_block(field(message, :text))]}

      media_kind_and_file_id(message) != {nil, nil} ->
        {:ok, media_blocks(message)}

      is_map(field(message, :location)) ->
        {:ok,
         [text_block(location_text(field(message, :location), field(message, :venue)))]}

      present_binary?(field(message, :caption)) ->
        {:ok, [text_block(field(message, :caption))]}

      true ->
        {:ok, [text_block(BullX.I18n.t("gateway.telegram.errors.unsupported_message"))]}
    end
  end

  def inbound_blocks(_message),
    do: {:error, Error.payload("invalid Telegram message payload")}

  @spec primary_text([map()]) :: String.t() | nil
  def primary_text([%{"kind" => "text", "body" => %{"text" => text}} | _rest])
      when is_binary(text) do
    text
  end

  def primary_text([_block | rest]), do: primary_text(rest)
  def primary_text([]), do: nil

  @spec render_outbound(term()) :: {:ok, String.t(), [String.t()]} | {:error, map()}
  def render_outbound(nil),
    do: {:error, Error.payload("Telegram delivery content is required")}

  def render_outbound([]),
    do: {:error, Error.payload("Telegram delivery content is required")}

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
     Error.unsupported("Telegram #{kind} delivery requires fallback_text", %{"kind" => kind})}
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
    do: {:error, Error.unsupported("unsupported Telegram content")}

  @spec split_message(String.t(), pos_integer()) :: [String.t()]
  def split_message(text, limit \\ @telegram_message_limit)
      when is_integer(limit) and limit > 0 do
    text
    |> to_string()
    |> String.trim()
    |> case do
      "" -> [BullX.I18n.t("gateway.telegram.delivery.fallback_text")]
      text -> chunk_text(text, min(limit, @telegram_message_limit))
    end
  end

  @spec stream_chunks(String.t(), pos_integer()) :: [String.t()]
  def stream_chunks(text, limit \\ @default_soft_limit) when is_integer(limit) and limit > 0 do
    split_message(text, min(limit, @telegram_message_limit))
  end

  @spec utf16_units(String.t()) :: non_neg_integer()
  def utf16_units(text) when is_binary(text) do
    for <<codepoint::utf8 <- text>>, reduce: 0 do
      count -> count + codepoint_units(codepoint)
    end
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

  defp text_block(text) do
    text =
      case String.trim(to_string(text)) do
        "" -> BullX.I18n.t("gateway.telegram.errors.unsupported_message")
        value -> value
      end

    %{"kind" => "text", "body" => %{"text" => text}}
  end

  defp media_blocks(message) do
    {kind, file_id} = media_kind_and_file_id(message)

    blocks = []
    blocks = blocks ++ caption_block(message)
    blocks ++ [media_block(kind, file_id, message)]
  end

  defp caption_block(message) do
    case field(message, :caption) do
      caption when is_binary(caption) and caption != "" -> [text_block(caption)]
      _caption -> []
    end
  end

  defp media_block(kind, file_id, message) do
    filename = media_filename(message, kind)
    fallback = filename || BullX.I18n.t("gateway.telegram.media.#{kind}")

    body =
      %{
        "url" => "telegram://file/#{file_id}",
        "fallback_text" => fallback
      }
      |> maybe_put("filename", filename)

    %{"kind" => Atom.to_string(kind), "body" => body}
  end

  defp media_kind_and_file_id(message) do
    cond do
      match?([_ | _], field(message, :photo)) ->
        {:image, photo_file_id(field(message, :photo))}

      is_map(field(message, :audio)) ->
        {:audio, field(field(message, :audio), :file_id)}

      is_map(field(message, :voice)) ->
        {:audio, field(field(message, :voice), :file_id)}

      is_map(field(message, :video)) ->
        {:video, field(field(message, :video), :file_id)}

      is_map(field(message, :animation)) ->
        {:video, field(field(message, :animation), :file_id)}

      is_map(field(message, :video_note)) ->
        {:video, field(field(message, :video_note), :file_id)}

      is_map(field(message, :document)) ->
        {:file, field(field(message, :document), :file_id)}

      is_map(field(message, :sticker)) ->
        {:image, field(field(message, :sticker), :file_id)}

      true ->
        {nil, nil}
    end
  end

  defp photo_file_id(photo_sizes) when is_list(photo_sizes) do
    photo_sizes
    |> Enum.reverse()
    |> Enum.find_value(&field(&1, :file_id))
  end

  defp photo_file_id(_photo_sizes), do: nil

  defp media_filename(message, :file) do
    case field(message, :document) do
      %{} = doc -> field(doc, :file_name)
      _doc -> nil
    end
  end

  defp media_filename(message, :audio) do
    case field(message, :audio) do
      %{} = audio -> field(audio, :file_name)
      _audio -> nil
    end
  end

  defp media_filename(message, :video) do
    case field(message, :video) do
      %{} = video -> field(video, :file_name)
      _video -> nil
    end
  end

  defp media_filename(_message, _kind), do: nil

  defp location_text(location, venue) do
    lat = field(location, :latitude)
    lon = field(location, :longitude)
    title = field(venue, :title)
    address = field(venue, :address)

    [
      maybe_line(title),
      maybe_line(address),
      "Location: #{lat}, #{lon}",
      "https://maps.google.com/?q=#{lat},#{lon}"
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp maybe_line(value) when is_binary(value) and value != "", do: value
  defp maybe_line(_value), do: nil

  defp field(%{} = map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(_value, _key), do: nil

  defp present_binary?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_binary?(_value), do: false

  defp stringify(%{} = body) do
    Map.new(body, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  defp stringify(body), do: body

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
