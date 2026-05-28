defmodule BullxTelegram.ContentMapper do
  @moduledoc false

  alias BullX.IMGateway.ChannelAdapter.Content

  @media_fields [
    {"photo", "image"},
    {"sticker", "image"},
    {"audio", "audio"},
    {"voice", "audio"},
    {"video", "video"},
    {"document", "file"}
  ]
  @message_limit 4_096

  @spec from_message(map()) :: {:ok, [map()]} | {:error, map()}
  def from_message(%{} = message) do
    blocks =
      []
      |> maybe_add_text(caption_or_text(message))
      |> add_media_blocks(message)
      |> maybe_add_location(message)
      |> case do
        [] -> [text_block(BullX.I18n.t("im_gateway.telegram.errors.unsupported_message"))]
        blocks -> Enum.reverse(blocks)
      end

    {:ok, blocks}
  end

  def from_message(_message),
    do: {:error, BullxTelegram.Error.payload("invalid Telegram message")}

  defdelegate primary_text(blocks), to: BullX.IMGateway.ChannelAdapter.Content

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

  def render_outbound([%{"type" => "control_notice"} = block | _rest]),
    do: render_control_notice(block)

  def render_outbound([%{"kind" => "control_notice"} = block | _rest]),
    do: render_control_notice(block)

  def render_outbound(%{"type" => "control_notice"} = block), do: render_control_notice(block)
  def render_outbound(%{"kind" => "control_notice"} = block), do: render_control_notice(block)
  def render_outbound(%{kind: "control_notice"} = block), do: render_control_notice(block)

  def render_outbound([%{"type" => "progress_notice"} = block | _rest]),
    do: render_fallback("progress_notice", block)

  def render_outbound([%{"kind" => "progress_notice"} = block | _rest]),
    do: render_fallback("progress_notice", block)

  def render_outbound(%{"type" => "progress_notice"} = block),
    do: render_fallback("progress_notice", block)

  def render_outbound(%{"kind" => "progress_notice"} = block),
    do: render_fallback("progress_notice", block)

  def render_outbound(%{kind: "progress_notice"} = block),
    do: block |> stringify_keys() |> render_fallback("progress_notice")

  def render_outbound([%{"type" => type} = block | _rest]), do: render_fallback(type, block)
  def render_outbound(%{"type" => type} = block), do: render_fallback(type, block)

  def render_outbound([%{"kind" => kind, "body" => body} | _rest]) do
    render_fallback(kind, body)
  end

  def render_outbound(%{"kind" => kind, "body" => body}), do: render_fallback(kind, body)

  def render_outbound(_content),
    do: {:error, BullxTelegram.Error.payload("Telegram delivery content is required")}

  defp render_control_notice(block) do
    case Content.delivery_text(block) do
      text when is_binary(text) and text != "" ->
        {:ok, split_text(text, @message_limit), ["control_notice_degraded_to_text"]}

      _value ->
        {:error, BullxTelegram.Error.payload("Telegram control notice requires text")}
    end
  end

  defdelegate utf16_units(text), to: BullX.Utils.Text
  defdelegate split_text(text, limit), to: BullX.Utils.Text

  defp maybe_add_text(blocks, nil), do: blocks
  defp maybe_add_text(blocks, ""), do: blocks
  defp maybe_add_text(blocks, text), do: [text_block(text) | blocks]

  defp add_media_blocks(blocks, message) do
    Enum.reduce(@media_fields, blocks, fn {field, kind}, acc ->
      case media_file_id(Map.get(message, field), field) do
        nil -> acc
        file_id -> [media_block(kind, file_id) | acc]
      end
    end)
  end

  defp maybe_add_location(blocks, %{"venue" => venue}) when is_map(venue) do
    location = Map.get(venue, "location") || %{}
    title = Map.get(venue, "title")
    address = Map.get(venue, "address")
    lat = Map.get(location, "latitude")
    lon = Map.get(location, "longitude")

    text =
      [title, address, coordinates(lat, lon), maps_url(lat, lon)]
      |> Enum.reject(&blank?/1)
      |> Enum.join("\n")

    maybe_add_text(blocks, text)
  end

  defp maybe_add_location(blocks, %{"location" => %{"latitude" => lat, "longitude" => lon}}) do
    maybe_add_text(blocks, [coordinates(lat, lon), maps_url(lat, lon)] |> Enum.join("\n"))
  end

  defp maybe_add_location(blocks, _message), do: blocks

  defp caption_or_text(message) do
    first_present([Map.get(message, "text"), Map.get(message, "caption")])
  end

  defp text_block(text), do: %{"type" => "text", "text" => String.trim(text)}

  defp media_block(kind, file_id) do
    %{
      "type" => normalized_media_type(kind),
      "url" => "telegram://file/#{file_id}",
      "fallback_text" => "[#{kind}]"
    }
  end

  defp normalized_media_type("image"), do: "image_url"
  defp normalized_media_type("video"), do: "video_url"
  defp normalized_media_type(_kind), do: "file"

  defp media_file_id(values, "photo") when is_list(values) do
    values
    |> Enum.max_by(&Map.get(&1, "file_size", 0), fn -> nil end)
    |> case do
      %{"file_id" => file_id} when is_binary(file_id) -> file_id
      _value -> nil
    end
  end

  defp media_file_id(%{"file_id" => file_id}, _field) when is_binary(file_id), do: file_id
  defp media_file_id(_value, _field), do: nil

  defp render_fallback(kind, body) do
    text =
      case Content.delivery_text(body) || get_in(body, ["fallback_text"]) do
        value when is_binary(value) and value != "" -> value
        _value -> BullX.I18n.t("im_gateway.telegram.delivery.fallback_text")
      end

    {:ok, [text], ["#{kind}_degraded_to_fallback_text"]}
  end

  defp stringify_keys(%{} = map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_value(value)}
      {key, value} when is_binary(key) -> {key, stringify_value(value)}
    end)
  end

  defp stringify_value(%{} = map), do: stringify_keys(map)
  defp stringify_value(values) when is_list(values), do: Enum.map(values, &stringify_value/1)
  defp stringify_value(value), do: value

  defp coordinates(lat, lon), do: "#{lat}, #{lon}"
  defp maps_url(lat, lon), do: "https://maps.google.com/?q=#{lat},#{lon}"

  defp first_present(values),
    do: Enum.find(values, fn value -> is_binary(value) and String.trim(value) != "" end)

  defp blank?(value), do: is_nil(value) or value == ""
end
