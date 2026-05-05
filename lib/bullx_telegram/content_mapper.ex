defmodule BullXTelegram.ContentMapper do
  @moduledoc """
  Converts Telegram message payloads and Gateway delivery content.
  """

  alias BullXGateway.Delivery.Content
  alias BullXTelegram.Error

  @telegram_message_limit 4_096
  @default_soft_limit 3_900

  @spec inbound_blocks(map()) :: {:ok, [Content.t()]} | {:error, map()}
  def inbound_blocks(message) when is_map(message) do
    cond do
      present_binary?(field(message, :text)) ->
        {:ok, [text_block(field(message, :text))]}

      media_file_id(message) != nil ->
        {:ok, media_blocks(message)}

      is_map(field(message, :location)) ->
        {:ok, [text_block(location_text(field(message, :location), field(message, :venue)))]}

      present_binary?(field(message, :caption)) ->
        {:ok, [text_block(field(message, :caption))]}

      true ->
        {:ok, [text_block(BullX.I18n.t("gateway.telegram.errors.unsupported_message"))]}
    end
  end

  def inbound_blocks(_message), do: {:error, Error.payload("Telegram message payload is invalid")}

  @spec render_outbound(Content.t() | nil) :: {:ok, String.t(), [String.t()]} | {:error, map()}
  def render_outbound(nil), do: {:error, Error.payload("Telegram delivery content is required")}

  def render_outbound(%Content{kind: :text, body: %{"text" => text}}) when is_binary(text) do
    {:ok, text, []}
  end

  def render_outbound(%Content{kind: kind, body: %{"fallback_text" => text}})
      when kind in [:image, :audio, :video, :file, :card] and is_binary(text) and text != "" do
    {:ok, text, ["#{kind}_degraded_to_fallback_text"]}
  end

  def render_outbound(%Content{} = content) do
    {:error,
     Error.unsupported("unsupported Telegram content kind", %{
       "kind" => Atom.to_string(content.kind)
     })}
  end

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
    |> codepoint_chunks(limit)
    |> Enum.map(&IO.iodata_to_binary/1)
  end

  defp codepoint_chunks(text, limit) do
    text
    |> codepoints()
    |> Enum.reduce({[], [], 0}, fn {binary, units}, {chunks, current, current_units} ->
      case current_units + units > limit and current != [] do
        true -> {[Enum.reverse(current) | chunks], [binary], units}
        false -> {chunks, [binary | current], current_units + units}
      end
    end)
    |> case do
      {chunks, [], _units} -> Enum.reverse(chunks)
      {chunks, current, _units} -> Enum.reverse([Enum.reverse(current) | chunks])
    end
  end

  defp codepoints(text) do
    for <<codepoint::utf8 <- text>> do
      {<<codepoint::utf8>>, codepoint_units(codepoint)}
    end
  end

  defp codepoint_units(codepoint) when codepoint > 0xFFFF, do: 2
  defp codepoint_units(_codepoint), do: 1

  defp text_block(text), do: %Content{kind: :text, body: %{"text" => text}}

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

  defp media_block(message) do
    {kind, file_id} = media_kind_and_file_id(message)
    fallback = BullX.I18n.t("gateway.telegram.media.#{kind}")

    %Content{
      kind: kind,
      body: %{
        "url" => "telegram://file/#{file_id}",
        "fallback_text" => fallback
      }
    }
  end

  defp media_blocks(message) do
    caption_block(message) ++ [media_block(message)]
  end

  defp caption_block(message) do
    case field(message, :caption) do
      caption when is_binary(caption) and caption != "" -> [text_block(caption)]
      _caption -> []
    end
  end

  defp media_file_id(message) do
    case media_kind_and_file_id(message) do
      {_kind, file_id} when is_binary(file_id) and file_id != "" -> file_id
      _other -> nil
    end
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

      is_map(field(message, :document)) ->
        {:file, field(field(message, :document), :file_id)}

      is_map(field(message, :sticker)) ->
        {:image, field(field(message, :sticker), :file_id)}

      true ->
        {:file, nil}
    end
  end

  defp photo_file_id(photo_sizes) when is_list(photo_sizes) do
    photo_sizes
    |> Enum.reverse()
    |> Enum.find_value(&field(&1, :file_id))
  end

  defp photo_file_id(_photo_sizes), do: nil

  defp maybe_line(value) when is_binary(value) and value != "", do: value
  defp maybe_line(_value), do: nil

  defp field(%{} = map, key) when is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_value, _key), do: nil

  defp present_binary?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_binary?(_value), do: false
end
