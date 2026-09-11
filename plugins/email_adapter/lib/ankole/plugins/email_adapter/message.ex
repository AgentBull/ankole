defmodule Ankole.Plugins.EmailAdapter.Message do
  @moduledoc """
  Projects one decoded MIME tree into the facts the adapter needs.

  The projection selects the readable text, lists the attachment parts with
  their bytes, and normalizes the threading and address headers.
  """

  alias Ankole.Plugins.EmailAdapter.{Address, Charset, HtmlText, Mime}
  alias Ankole.Plugins.EmailAdapter.Mime.Part

  @message_id_token ~r/<([^<>\s]+)>/
  @month_numbers %{
    "jan" => 1,
    "feb" => 2,
    "mar" => 3,
    "apr" => 4,
    "may" => 5,
    "jun" => 6,
    "jul" => 7,
    "aug" => 8,
    "sep" => 9,
    "oct" => 10,
    "nov" => 11,
    "dec" => 12
  }

  defstruct message_id: nil,
            in_reply_to: [],
            references: [],
            from: nil,
            reply_to: [],
            to: [],
            cc: [],
            subject: nil,
            date: nil,
            text: nil,
            attachments: [],
            unsupported_charsets: [],
            auto_submitted: false,
            authentication_results: []

  @type attachment :: %{
          index: pos_integer(),
          name: String.t(),
          mime_type: String.t(),
          size: non_neg_integer(),
          body: binary()
        }

  @type t :: %__MODULE__{
          message_id: String.t() | nil,
          in_reply_to: [String.t()],
          references: [String.t()],
          from: Address.mailbox() | nil,
          reply_to: [Address.mailbox()],
          to: [Address.mailbox()],
          cc: [Address.mailbox()],
          subject: String.t() | nil,
          date: DateTime.t() | nil,
          text: String.t() | nil,
          attachments: [attachment()],
          unsupported_charsets: [String.t()],
          auto_submitted: boolean(),
          authentication_results: [String.t()]
        }

  @spec decode(binary()) :: t()
  def decode(raw) when is_binary(raw) do
    part = Mime.parse(raw)
    {texts, attachments, charsets} = collect(part, {[], [], []})

    %__MODULE__{
      text: readable_text(Enum.reverse(texts)),
      attachments:
        attachments |> Enum.reverse() |> Enum.with_index(1) |> Enum.map(&index_attachment/1),
      unsupported_charsets: charsets |> Enum.reverse() |> Enum.uniq()
    }
    |> put_headers(part.headers)
  end

  @doc "Projects a message whose body was not fetched."
  @spec decode_headers(binary()) :: t()
  def decode_headers(raw) when is_binary(raw) do
    put_headers(%__MODULE__{}, Mime.parse_headers(raw))
  end

  @doc "Strips the `<>` from one Message-ID token and returns nil for an unusable value."
  @spec normalize_message_id(String.t() | nil) :: String.t() | nil
  def normalize_message_id(nil), do: nil

  def normalize_message_id(value) when is_binary(value) do
    case message_id_tokens(value) do
      [first | _rest] -> first
      [] -> bare_message_id(value)
    end
  end

  @spec message_id_tokens(String.t() | nil) :: [String.t()]
  def message_id_tokens(nil), do: []

  def message_id_tokens(value) when is_binary(value) do
    @message_id_token
    |> Regex.scan(value)
    |> Enum.map(fn [_all, id] -> id end)
    |> Enum.uniq()
  end

  @doc "Removes reply and forward prefixes so the thread name stays stable."
  @spec base_subject(String.t() | nil) :: String.t() | nil
  def base_subject(nil), do: nil

  def base_subject(subject) do
    subject
    |> String.replace(~r/\A(\s*((re|fw|fwd|aw|sv|回复|答复|转发)\s*[:：]\s*)|\s*\[\d+\]\s*)+/iu, "")
    |> String.trim()
    |> case do
      "" -> nil
      base -> base
    end
  end

  defp put_headers(%__MODULE__{} = message, headers) do
    %{
      message
      | message_id: headers |> Mime.header("message-id") |> normalize_message_id(),
        in_reply_to: headers |> Mime.header("in-reply-to") |> message_id_tokens(),
        references: headers |> Mime.header("references") |> message_id_tokens(),
        from: headers |> address_list("from") |> List.first(),
        reply_to: address_list(headers, "reply-to"),
        to: address_list(headers, "to"),
        cc: address_list(headers, "cc"),
        subject: headers |> Mime.header("subject") |> Mime.decode_text() |> presence(),
        date: headers |> Mime.header("date") |> parse_date(),
        auto_submitted: auto_submitted?(headers),
        authentication_results: Mime.headers(headers, "authentication-results")
    }
  end

  # The structure is parsed on the masked header, so an encoded display name
  # cannot inject another mailbox; decoding touches only the display name.
  defp address_list(headers, name) do
    headers
    |> Mime.headers(name)
    |> Enum.flat_map(fn value ->
      {masked, words} = Mime.mask_encoded_words(value)

      masked
      |> Address.parse_list()
      |> Enum.map(fn mailbox ->
        %{mailbox | name: mailbox.name |> Mime.restore_encoded_words(words) |> presence()}
      end)
    end)
    |> Enum.uniq_by(& &1.address)
  end

  # Bulk and automatic mail must never wake the Agent or receive a notice.
  defp auto_submitted?(headers) do
    auto = headers |> Mime.header("auto-submitted") |> downcase()
    precedence = headers |> Mime.header("precedence") |> downcase()

    auto not in [nil, "no"] or precedence in ["bulk", "list", "junk"] or
      is_binary(Mime.header(headers, "list-id"))
  end

  # Walks the tree once. `multipart/alternative` keeps only its best child;
  # every other container contributes all of its children.
  defp collect(%Part{type: "multipart", subtype: "alternative", parts: parts}, acc)
       when is_list(parts) do
    case best_alternative(parts) do
      nil -> acc
      part -> collect(part, acc)
    end
  end

  defp collect(%Part{type: "multipart", parts: parts}, acc) when is_list(parts) do
    Enum.reduce(parts, acc, &collect/2)
  end

  defp collect(%Part{type: "message", subtype: "rfc822"} = part, {texts, attachments, charsets}) do
    {texts, [attachment(part, "message.eml", "message/rfc822") | attachments], charsets}
  end

  defp collect(%Part{} = part, {texts, attachments, charsets}) do
    cond do
      attachment?(part) ->
        {texts, [attachment(part, filename(part), mime_type(part)) | attachments], charsets}

      part.type == "text" and part.subtype in ["plain", "html"] ->
        case Charset.to_utf8(part.body || "", part.params["charset"]) do
          {:ok, text} ->
            {[{part.subtype, text} | texts], attachments, charsets}

          {:error, {:unsupported_charset, charset}} ->
            {[{part.subtype, Charset.ascii_only(part.body || "")} | texts], attachments,
             [charset | charsets]}
        end

      true ->
        {texts, [attachment(part, filename(part), mime_type(part)) | attachments], charsets}
    end
  end

  defp best_alternative(parts) do
    Enum.find(parts, &text_leaf?(&1, "plain")) ||
      Enum.find(parts, &text_leaf?(&1, "html")) ||
      Enum.find(parts, &(&1.type == "multipart")) ||
      List.first(parts)
  end

  defp text_leaf?(%Part{type: "text", subtype: subtype} = part, subtype),
    do: not attachment?(part)

  defp text_leaf?(_part, _subtype), do: false

  defp attachment?(%Part{disposition: "attachment"}), do: true

  defp attachment?(%Part{} = part),
    do: is_binary(part.disposition_params["filename"]) or is_binary(part.params["name"])

  defp readable_text(texts) do
    plain = texts |> Enum.filter(&(elem(&1, 0) == "plain")) |> Enum.map(&elem(&1, 1))
    html = texts |> Enum.filter(&(elem(&1, 0) == "html")) |> Enum.map(&elem(&1, 1))

    case Enum.join(plain, "\n\n") |> String.trim() do
      "" -> html |> Enum.map_join("\n\n", &HtmlText.to_text/1) |> String.trim() |> presence()
      joined -> joined
    end
  end

  defp attachment(%Part{} = part, name, mime_type) do
    body = part.body || ""
    %{name: name, mime_type: mime_type, size: byte_size(body), body: body}
  end

  defp index_attachment({attachment, index}), do: Map.put(attachment, :index, index)

  defp filename(%Part{} = part) do
    presence(part.disposition_params["filename"]) || presence(part.params["name"]) ||
      "attachment-#{part.subtype}"
  end

  defp mime_type(%Part{type: type, subtype: subtype}), do: "#{type}/#{subtype}"

  defp bare_message_id(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> if Regex.match?(~r/\A[^\s<>]+@[^\s<>]+\z/, trimmed), do: trimmed, else: nil
    end
  end

  defp parse_date(nil), do: nil

  defp parse_date(value) do
    with [_all, day, month, year, hour, minute, second, zone] <-
           Regex.run(
             ~r/(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([+-]\d{4}|[A-Z]{1,5})?/,
             value <> " "
           ),
         month_number when is_integer(month_number) <- @month_numbers[String.downcase(month)],
         {:ok, naive} <-
           NaiveDateTime.new(
             String.to_integer(year),
             month_number,
             String.to_integer(day),
             String.to_integer(hour),
             String.to_integer(minute),
             if(second == "", do: 0, else: String.to_integer(second))
           ),
         {:ok, utc} <- DateTime.from_naive(naive, "Etc/UTC") do
      DateTime.add(utc, -zone_offset_seconds(zone), :second, Calendar.UTCOnlyTimeZoneDatabase)
    else
      _invalid -> nil
    end
  end

  defp zone_offset_seconds(<<sign, hours::binary-size(2), minutes::binary-size(2)>>)
       when sign in [?+, ?-] do
    seconds = String.to_integer(hours) * 3600 + String.to_integer(minutes) * 60
    if sign == ?-, do: -seconds, else: seconds
  end

  defp zone_offset_seconds(_zone), do: 0

  defp downcase(nil), do: nil
  defp downcase(value), do: value |> String.trim() |> String.downcase()

  defp presence(nil), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
