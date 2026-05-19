defmodule Feishu.ContentMapper do
  @moduledoc false

  @media_kinds ~w(image file audio video)

  @spec from_message(map(), Feishu.Source.t()) :: {:ok, [map()]} | {:error, map()}
  def from_message(message, source) when is_map(message) do
    type = Map.get(message, "message_type") || Map.get(message, :message_type)
    body = decoded_content(message)

    blocks =
      case type do
        "text" -> [text_block(text_from_body(body))]
        "post" -> [text_block(post_text(body))]
        "interactive" -> [card_block(body)]
        "image" -> [media_block("image", message, body, source)]
        "file" -> [media_block("file", message, body, source)]
        "audio" -> [media_block("audio", message, body, source)]
        "video" -> [media_block("video", message, body, source)]
        "sticker" -> [text_block("[sticker]")]
        "emotion" -> [text_block(emotion_text(body))]
        "emoji" -> [text_block(emotion_text(body))]
        nil -> [text_block(text_from_body(body))]
        _other -> [text_block(fallback_text(type))]
      end

    {:ok, Enum.reject(blocks, &is_nil/1)}
  end

  def from_message(_message, _source),
    do: {:error, Feishu.Error.payload("invalid Feishu message")}

  @spec primary_text([map()]) :: String.t() | nil
  def primary_text([%{"type" => "text", "text" => text} | _rest])
      when is_binary(text) do
    text
  end

  def primary_text([%{"kind" => "text", "body" => %{"text" => text}} | _rest])
      when is_binary(text) do
    text
  end

  def primary_text([_block | rest]), do: primary_text(rest)
  def primary_text([]), do: nil

  @spec render_outbound(term(), Feishu.Source.t() | nil) ::
          {:ok, map(), [String.t()]} | {:error, map()}
  def render_outbound(content, source \\ nil)

  def render_outbound([block | _rest], source), do: render_outbound(block, source)

  def render_outbound(%{"type" => "text", "text" => text}, _source)
      when is_binary(text) and text != "" do
    {:ok, %{msg_type: "text", content: Jason.encode!(%{text: text})}, []}
  end

  def render_outbound(%{"kind" => "text", "body" => %{"text" => text}}, _source)
      when is_binary(text) and text != "" do
    {:ok, %{msg_type: "text", content: Jason.encode!(%{text: text})}, []}
  end

  def render_outbound(%{kind: "text", body: %{text: text}}, source),
    do: render_outbound(%{"kind" => "text", "body" => %{"text" => text}}, source)

  def render_outbound(
        %{"type" => "card", "format" => format, "payload" => payload},
        _source
      )
      when format in ["feishu.card", "feishu.card.v2"] and is_map(payload) do
    {:ok, %{msg_type: "interactive", content: Jason.encode!(payload)}, []}
  end

  def render_outbound(
        %{"kind" => "card", "body" => %{"format" => format, "payload" => payload}},
        _source
      )
      when format in ["feishu.card", "feishu.card.v2"] and is_map(payload) do
    {:ok, %{msg_type: "interactive", content: Jason.encode!(payload)}, []}
  end

  def render_outbound(%{"type" => type} = part, source)
      when type in ["image_url", "image", "video_url", "file"] do
    part
    |> outbound_media_block()
    |> render_outbound(source)
  end

  def render_outbound(%{"kind" => kind, "body" => body}, %Feishu.Source{} = source)
      when kind in @media_kinds do
    with {:ok, file} <- outbound_file(body, kind, source),
         {:ok, key} <- upload_media(file, kind, source) do
      {:ok, rendered_media(kind, key), []}
    else
      {:error, %FeishuOpenAPI.Error{} = error} ->
        {:error, Feishu.Error.map(error)}

      {:error, %{} = error} ->
        {:error, error}

      {:degrade, warning} ->
        render_media_fallback(kind, body, warning)
    end
  end

  def render_outbound(%{"kind" => kind, "body" => body}, _source) when kind in @media_kinds do
    render_media_fallback(kind, body, "#{kind}_degraded_to_fallback_text")
  end

  def render_outbound(_content, _source),
    do: {:error, Feishu.Error.unsupported("unsupported Feishu content")}

  defp decoded_content(%{"content" => content}), do: decode_content(content)
  defp decoded_content(%{content: content}), do: decode_content(content)
  defp decoded_content(_message), do: %{}

  defp decode_content(content) when is_map(content), do: stringify_keys(content)

  defp decode_content(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, decoded} when is_map(decoded) -> stringify_keys(decoded)
      _error -> %{"text" => content}
    end
  end

  defp decode_content(_content), do: %{}

  defp text_from_body(%{"text" => text}) when is_binary(text), do: String.trim(text)
  defp text_from_body(%{"title" => title}) when is_binary(title), do: String.trim(title)
  defp text_from_body(_body), do: ""

  defp post_text(%{"title" => title, "content" => content}) do
    [title, flatten_post_content(content)]
    |> Enum.filter(&present?/1)
    |> Enum.join("\n")
  end

  defp post_text(%{"content" => content}), do: flatten_post_content(content)
  defp post_text(other), do: text_from_body(other)

  defp flatten_post_content(content) when is_list(content) do
    content
    |> List.flatten()
    |> Enum.map(&post_fragment/1)
    |> Enum.filter(&present?/1)
    |> Enum.join("")
    |> String.trim()
  end

  defp flatten_post_content(_content), do: ""

  defp post_fragment(%{"tag" => "text", "text" => text}) when is_binary(text), do: text
  defp post_fragment(%{"tag" => "a", "text" => text}) when is_binary(text), do: text
  defp post_fragment(%{"tag" => "at", "user_name" => name}) when is_binary(name), do: "@" <> name
  defp post_fragment(_fragment), do: ""

  defp card_block(payload) when is_map(payload) do
    %{
      "type" => "card",
      "format" => "feishu.card",
      "fallback_text" => card_fallback(payload),
      "payload" => payload
    }
  end

  defp media_block(kind, message, body, source) do
    message_id = Map.get(message, "message_id") || Map.get(message, :message_id) || "unknown"
    key = media_key(body, kind)
    filename = Map.get(body, "file_name") || Map.get(body, "name")
    fallback = filename || "[#{kind}]"

    kind
    |> normalized_media_type()
    |> normalized_media_block(media_url(kind, message_id, key, source), fallback, filename)
  end

  defp normalized_media_type("image"), do: "image_url"
  defp normalized_media_type("video"), do: "video_url"
  defp normalized_media_type(_kind), do: "file"

  defp normalized_media_block(type, url, fallback, filename) do
    %{
      "type" => type,
      "url" => url,
      "fallback_text" => fallback
    }
    |> maybe_put("filename", filename)
    |> maybe_put("media_type", media_type_for(type))
  end

  defp media_type_for("image_url"), do: "image/png"
  defp media_type_for("video_url"), do: "video/mp4"
  defp media_type_for("file"), do: "application/octet-stream"

  defp media_url(kind, message_id, key, %Feishu.Source{} = source)
       when is_binary(key) and key != "" and is_binary(message_id) and message_id != "unknown" do
    case source.inline_media_max_bytes do
      max when is_integer(max) and max > 0 ->
        inline_media_url(kind, message_id, key, source, max)

      _max ->
        feishu_resource_url(message_id, key)
    end
  end

  defp media_url(_kind, message_id, key, _source), do: feishu_resource_url(message_id, key)

  defp inline_media_url(kind, message_id, key, %Feishu.Source{} = source, max_bytes) do
    case FeishuOpenAPI.download(
           Feishu.Source.client!(source),
           "/open-apis/im/v1/messages/:message_id/resources/:file_key",
           path_params: %{message_id: message_id, file_key: key},
           query: [type: kind]
         ) do
      {:ok, %{body: body}} when is_binary(body) and byte_size(body) <= max_bytes ->
        "data:#{media_mime(kind)};base64," <> Base.encode64(body)

      _other ->
        feishu_resource_url(message_id, key)
    end
  end

  defp feishu_resource_url(message_id, key) do
    "feishu://message-resource/#{message_id}/#{key || "resource"}"
  end

  defp outbound_file(body, kind, %Feishu.Source{} = source) do
    with {:ok, data, filename} <- outbound_file_data(body, kind),
         :ok <- check_size(data, source.inline_media_max_bytes) do
      {:ok, {data, filename}}
    end
  end

  defp outbound_file_data(%{"url" => "data:" <> _rest = uri} = body, kind) do
    with {:ok, data} <- decode_data_uri(uri) do
      {:ok, data, outbound_filename(body, kind)}
    end
  end

  defp outbound_file_data(%{"data" => "data:" <> _rest = uri} = body, kind) do
    with {:ok, data} <- decode_data_uri(uri) do
      {:ok, data, outbound_filename(body, kind)}
    end
  end

  defp outbound_file_data(%{"url" => "file://" <> path} = body, kind),
    do: read_path(path, body, kind)

  defp outbound_file_data(%{"url" => "/" <> _rest = path} = body, kind),
    do: read_path(path, body, kind)

  defp outbound_file_data(_body, kind), do: {:degrade, "#{kind}_degraded_to_fallback_text"}

  defp read_path(path, body, kind) do
    case File.read(path) do
      {:ok, data} -> {:ok, data, Map.get(body, "filename") || Path.basename(path)}
      {:error, _reason} -> {:degrade, "#{kind}_degraded_to_fallback_text"}
    end
  end

  defp decode_data_uri(uri) do
    case String.split(uri, ",", parts: 2) do
      [metadata, payload] ->
        if String.ends_with?(metadata, ";base64") do
          Base.decode64(payload)
        else
          {:ok, URI.decode(payload)}
        end

      _other ->
        {:error, Feishu.Error.payload("invalid media data URI")}
    end
  end

  defp check_size(data, max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    case byte_size(data) <= max_bytes do
      true -> :ok
      false -> {:degrade, "media_exceeds_inline_limit"}
    end
  end

  defp check_size(_data, _max_bytes), do: {:degrade, "media_upload_disabled"}

  defp upload_media({data, filename}, "image", %Feishu.Source{} = source) do
    case FeishuOpenAPI.upload(Feishu.Source.client!(source), "/open-apis/im/v1/images",
           fields: [image_type: "message"],
           file: {:iodata, data, filename}
         ) do
      {:ok, %{"data" => %{"image_key" => key}}} when is_binary(key) and key != "" -> {:ok, key}
      {:ok, _response} -> {:error, Feishu.Error.payload("Feishu image upload missing image_key")}
      {:error, error} -> {:error, error}
    end
  end

  defp upload_media({data, filename}, kind, %Feishu.Source{} = source) do
    case FeishuOpenAPI.upload(Feishu.Source.client!(source), "/open-apis/im/v1/files",
           fields: [file_type: feishu_file_type(kind), file_name: filename],
           file: {:iodata, data, filename}
         ) do
      {:ok, %{"data" => %{"file_key" => key}}} when is_binary(key) and key != "" -> {:ok, key}
      {:ok, _response} -> {:error, Feishu.Error.payload("Feishu file upload missing file_key")}
      {:error, error} -> {:error, error}
    end
  end

  defp rendered_media("image", key),
    do: %{msg_type: "image", content: Jason.encode!(%{image_key: key})}

  defp rendered_media(kind, key), do: %{msg_type: kind, content: Jason.encode!(%{file_key: key})}

  defp render_media_fallback(kind, body, warning) do
    case Map.get(body, "fallback_text") do
      text when is_binary(text) and text != "" ->
        {:ok, %{msg_type: "text", content: Jason.encode!(%{text: text})}, [warning]}

      _value ->
        {:error, Feishu.Error.unsupported("Feishu #{kind} delivery requires fallback_text")}
    end
  end

  defp outbound_filename(body, kind) do
    Map.get(body, "filename") || Map.get(body, "file_name") ||
      "bullx-#{kind}.#{default_ext(kind)}"
  end

  defp feishu_file_type("audio"), do: "opus"
  defp feishu_file_type("video"), do: "mp4"
  defp feishu_file_type(_kind), do: "stream"

  defp default_ext("image"), do: "png"
  defp default_ext("audio"), do: "opus"
  defp default_ext("video"), do: "mp4"
  defp default_ext(_kind), do: "bin"

  defp media_mime("image"), do: "image/png"
  defp media_mime("audio"), do: "audio/ogg"
  defp media_mime("video"), do: "video/mp4"
  defp media_mime(_kind), do: "application/octet-stream"

  defp media_key(body, "image"), do: Map.get(body, "image_key")
  defp media_key(body, "file"), do: Map.get(body, "file_key")
  defp media_key(body, "audio"), do: Map.get(body, "file_key") || Map.get(body, "audio_key")
  defp media_key(body, "video"), do: Map.get(body, "file_key") || Map.get(body, "video_key")

  defp text_block(text) do
    text =
      case String.trim(to_string(text)) do
        "" -> BullX.I18n.t("eventbus.feishu.errors.unsupported_message")
        value -> value
      end

    %{"type" => "text", "text" => text}
  end

  defp outbound_media_block(%{"type" => "image_url"} = part), do: local_media_block("image", part)
  defp outbound_media_block(%{"type" => "image"} = part), do: local_media_block("image", part)
  defp outbound_media_block(%{"type" => "video_url"} = part), do: local_media_block("video", part)
  defp outbound_media_block(%{"type" => "file"} = part), do: local_media_block("file", part)

  defp local_media_block(kind, part) do
    %{
      "kind" => kind,
      "body" =>
        part
        |> Map.take(["url", "data", "filename", "file_name", "fallback_text"])
        |> Map.new()
    }
  end

  defp emotion_text(%{"emoji_type" => emoji}) when is_binary(emoji), do: ":" <> emoji <> ":"
  defp emotion_text(%{"text" => text}) when is_binary(text), do: text
  defp emotion_text(_body), do: "[sticker]"

  defp fallback_text(type) when type in @media_kinds, do: "[#{type}]"
  defp fallback_text(_type), do: BullX.I18n.t("eventbus.feishu.errors.unsupported_message")

  defp card_fallback(%{"header" => %{"title" => %{"content" => content}}})
       when is_binary(content) do
    content
  end

  defp card_fallback(%{"config" => %{"summary" => summary}}) when is_binary(summary), do: summary
  defp card_fallback(_payload), do: "[card]"

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_nested(value)}
      {key, value} -> {key, stringify_nested(value)}
    end)
  end

  defp stringify_nested(%{} = map), do: stringify_keys(map)
  defp stringify_nested(values) when is_list(values), do: Enum.map(values, &stringify_nested/1)
  defp stringify_nested(value), do: value

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
