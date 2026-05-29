defmodule Feishu.ContentMapper do
  @moduledoc false

  alias BullX.IMGateway.ChannelAdapter.Content

  import BullX.Utils.Map, only: [maybe_put: 3]

  @media_kinds ~w(image file audio video)

  @spec from_message(map(), Feishu.Source.t()) ::
          {:ok, [map()]} | {:ignore, atom()} | {:error, map()}
  def from_message(message, source) when is_map(message) do
    type = Map.get(message, "message_type") || Map.get(message, :message_type)
    body = decoded_content(message)
    mention_replacements = mention_replacements(message)

    case content_blocks(type, body, message, source, mention_replacements) do
      [_ | _] = blocks -> {:ok, blocks}
      [] -> {:ignore, :unsupported_message}
      :unsupported -> {:ignore, :unsupported_message}
    end
  end

  def from_message(_message, _source),
    do: {:error, Feishu.Error.payload("invalid Feishu message")}

  defdelegate primary_text(blocks), to: BullX.IMGateway.ChannelAdapter.Content

  defp content_blocks("text", body, _message, _source, mention_replacements) do
    body
    |> text_from_body()
    |> normalize_text_mentions(mention_replacements)
    |> text_block()
    |> List.wrap()
  end

  defp content_blocks("post", body, _message, _source, mention_replacements) do
    body
    |> post_text()
    |> normalize_text_mentions(mention_replacements)
    |> text_block()
    |> List.wrap()
  end

  defp content_blocks("interactive", body, _message, _source, _mention_replacements),
    do: [card_block(body)]

  defp content_blocks(type, body, message, source, _mention_replacements)
       when type in @media_kinds,
       do: [media_block(type, message, body, source)]

  defp content_blocks(type, body, _message, _source, _mention_replacements)
       when type in ["emotion", "emoji"],
       do: [text_block(emotion_text(body))]

  defp content_blocks("sticker", _body, _message, _source, _mention_replacements),
    do: [text_block("[sticker]")]

  defp content_blocks(nil, body, _message, _source, mention_replacements) do
    body
    |> text_from_body()
    |> normalize_text_mentions(mention_replacements)
    |> text_block()
    |> List.wrap()
  end

  defp content_blocks(_type, _body, _message, _source, _mention_replacements), do: :unsupported

  @spec render_outbound(term(), Feishu.Source.t() | nil, keyword()) ::
          {:ok, map(), [String.t()]} | {:error, map()}
  def render_outbound(content, source \\ nil, opts \\ [])

  def render_outbound([block | _rest], source, opts), do: render_outbound(block, source, opts)

  def render_outbound(%{"type" => "text", "text" => text}, _source, _opts)
      when is_binary(text) and text != "" do
    {:ok, %{msg_type: "text", content: Jason.encode!(%{text: text})}, []}
  end

  def render_outbound(%{"kind" => "text", "body" => %{"text" => text}}, _source, _opts)
      when is_binary(text) and text != "" do
    {:ok, %{msg_type: "text", content: Jason.encode!(%{text: text})}, []}
  end

  def render_outbound(%{kind: "text", body: %{text: text}}, source, opts),
    do: render_outbound(%{"kind" => "text", "body" => %{"text" => text}}, source, opts)

  def render_outbound(%{"type" => "control_notice"} = block, _source, opts),
    do: render_control_notice(block, opts)

  def render_outbound(%{"kind" => "control_notice"} = block, _source, opts),
    do: render_control_notice(block, opts)

  def render_outbound(%{kind: "control_notice"} = block, _source, opts),
    do: block |> stringify_keys() |> render_control_notice(opts)

  def render_outbound(%{"type" => "progress_notice"} = block, _source, _opts),
    do: render_progress_notice(block)

  def render_outbound(%{"kind" => "progress_notice"} = block, _source, _opts),
    do: render_progress_notice(block)

  def render_outbound(%{kind: "progress_notice"} = block, _source, _opts),
    do: block |> stringify_keys() |> render_progress_notice()

  def render_outbound(
        %{"type" => "card", "format" => format, "payload" => payload},
        _source,
        _opts
      )
      when format in ["feishu.card", "feishu.card.v2"] and is_map(payload) do
    {:ok, %{msg_type: "interactive", content: Jason.encode!(payload)}, []}
  end

  def render_outbound(
        %{"kind" => "card", "body" => %{"format" => format, "payload" => payload}},
        _source,
        _opts
      )
      when format in ["feishu.card", "feishu.card.v2"] and is_map(payload) do
    {:ok, %{msg_type: "interactive", content: Jason.encode!(payload)}, []}
  end

  def render_outbound(%{"type" => type} = part, source, opts)
      when type in ["image_url", "image", "video_url", "file"] do
    part
    |> outbound_media_block()
    |> render_outbound(source, opts)
  end

  def render_outbound(%{"kind" => kind, "body" => body}, %Feishu.Source{} = source, _opts)
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

  def render_outbound(%{"kind" => kind, "body" => body}, _source, _opts)
      when kind in @media_kinds do
    render_media_fallback(kind, body, "#{kind}_degraded_to_fallback_text")
  end

  def render_outbound(_content, _source, _opts),
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

  defp render_control_notice(block, opts) do
    cond do
      Keyword.get(opts, :force_text_notice?, false) ->
        render_control_notice_text(block, ["control_notice_degraded_to_text"])

      Keyword.get(opts, :scope_kind) in ["dm", :dm, "p2p", :p2p] ->
        render_control_notice_system(block)

      true ->
        render_control_notice_card(block)
    end
  end

  defp render_control_notice_system(block) do
    body = notice_body(block)
    text = system_notice_text(body)

    content =
      %{
        "type" => "divider",
        "params" => %{
          "divider_text" =>
            %{"text" => text}
            |> maybe_put("i18n_text", system_notice_i18n(body))
        },
        "options" => %{"need_rollup" => true}
      }

    {:ok, %{msg_type: "system", content: Jason.encode!(content)}, []}
  end

  defp render_control_notice_text(block, warnings) do
    case Content.delivery_text(block) do
      text when is_binary(text) and text != "" ->
        {:ok, %{msg_type: "text", content: Jason.encode!(%{text: text})}, warnings}

      _value ->
        {:error, Feishu.Error.payload("Feishu control notice requires text")}
    end
  end

  defp render_control_notice_card(block) do
    case Content.delivery_text(block) do
      text when is_binary(text) and text != "" ->
        {:ok, interactive_card(compact_notice_card(text, false)), []}

      _value ->
        {:error, Feishu.Error.payload("Feishu control notice requires text")}
    end
  end

  defp render_progress_notice(block) do
    case Content.delivery_text(block) do
      text when is_binary(text) and text != "" ->
        {:ok, interactive_card(compact_notice_card(text, progress_divider?(block))), []}

      _value ->
        {:error, Feishu.Error.payload("Feishu progress notice requires text")}
    end
  end

  defp interactive_card(card), do: %{msg_type: "interactive", content: Jason.encode!(card)}

  defp compact_notice_card(text, divider?) do
    elements =
      case divider? do
        true -> [compact_hr(), compact_text(text)]
        false -> [compact_text(text)]
      end

    %{
      "schema" => "2.0",
      "config" => %{"update_multi" => true},
      "body" => %{
        "direction" => "vertical",
        "horizontal_spacing" => "8px",
        "vertical_spacing" => "8px",
        "horizontal_align" => "left",
        "vertical_align" => "top",
        "padding" => "12px 12px 12px 12px",
        "elements" => elements
      }
    }
  end

  defp compact_hr, do: %{"tag" => "hr", "margin" => "0px 0px 0px 0px"}

  defp compact_text(text) do
    %{
      "tag" => "div",
      "text" => %{
        "tag" => "plain_text",
        "content" => text,
        "text_size" => "notation",
        "text_align" => "left",
        "text_color" => "grey"
      },
      "margin" => "0px 0px 0px 0px"
    }
  end

  defp progress_divider?(%{"show_divider" => true}), do: true
  defp progress_divider?(%{"body" => %{"show_divider" => true}}), do: true
  defp progress_divider?(_block), do: false

  defp notice_body(%{"kind" => "control_notice", "body" => body}) when is_map(body),
    do: stringify_keys(body)

  defp notice_body(%{"type" => "control_notice"} = block), do: stringify_keys(block)

  defp system_notice_text(body) do
    body
    |> first_string(["short_text", "text"])
    |> case do
      nil -> "Notice"
      text -> String.slice(text, 0, 20)
    end
  end

  defp system_notice_i18n(%{"i18n" => i18n}) when is_map(i18n) do
    i18n
    |> stringify_keys()
    |> Enum.flat_map(fn
      {locale, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> []
          text -> [{locale, String.slice(text, 0, 20)}]
        end

      _entry ->
        []
    end)
    |> case do
      [] -> nil
      entries -> Map.new(entries)
    end
  end

  defp system_notice_i18n(_body), do: nil

  defp normalize_text_mentions(text, replacements)
       when is_binary(text) and is_list(replacements) do
    text
    |> String.trim()
    |> strip_leading_mentions(replacements)
    |> replace_remaining_mentions(replacements)
    |> String.trim()
  end

  defp normalize_text_mentions(text, _replacements), do: text

  defp strip_leading_mentions(text, replacements) do
    trimmed = String.trim_leading(text)

    case Enum.find(replacements, fn {key, _display} -> String.starts_with?(trimmed, key) end) do
      {key, _display} ->
        trimmed
        |> binary_part(byte_size(key), byte_size(trimmed) - byte_size(key))
        |> strip_leading_mentions(replacements)

      nil ->
        trimmed
    end
  end

  defp replace_remaining_mentions(text, replacements) do
    Enum.reduce(replacements, text, fn {key, display}, acc ->
      String.replace(acc, key, display)
    end)
  end

  defp mention_replacements(message) do
    message
    |> message_mentions()
    |> Enum.flat_map(&mention_replacement/1)
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.sort_by(fn {key, _display} -> byte_size(key) end, :desc)
  end

  defp message_mentions(%{"mentions" => mentions}) when is_list(mentions), do: mentions
  defp message_mentions(%{mentions: mentions}) when is_list(mentions), do: mentions
  defp message_mentions(_message), do: []

  defp mention_replacement(mention) when is_map(mention) do
    mention = stringify_keys(mention)

    mention
    |> first_string(["key", "mention_key", "placeholder"])
    |> mention_key_variants()
    |> Enum.map(&{&1, mention_display(mention)})
  end

  defp mention_replacement(_mention), do: []

  defp mention_key_variants(key) when is_binary(key) do
    trimmed = String.trim(key)

    cond do
      trimmed == "" ->
        []

      String.starts_with?(trimmed, "@") ->
        [trimmed]

      true ->
        ["@" <> trimmed, trimmed]
    end
  end

  defp mention_key_variants(_key), do: []

  defp mention_display(mention) do
    case first_string(mention, ["name", "user_name", "text"]) do
      name when is_binary(name) ->
        "@" <> String.trim_leading(String.trim(name), "@")

      nil ->
        mention_id_display(mention)
    end
  end

  defp mention_id_display(%{"id" => ids}) when is_map(ids) do
    case first_string(ids, ["open_id", "user_id", "union_id"]) do
      id when is_binary(id) -> "@" <> id
      nil -> ""
    end
  end

  defp mention_id_display(_mention), do: ""

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

  defp text_block(""), do: nil
  defp text_block(text), do: %{"type" => "text", "text" => text}

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

  defp card_fallback(%{"header" => %{"title" => %{"content" => content}}})
       when is_binary(content) do
    content
  end

  defp card_fallback(%{"config" => %{"summary" => summary}}) when is_binary(summary), do: summary
  defp card_fallback(_payload), do: "[card]"

  defp first_string(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_binary(value) -> present_string(value)
        _value -> nil
      end
    end)
  end

  defp present_string(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

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
end
