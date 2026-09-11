defmodule Ankole.Plugins.EmailAdapter.Mime do
  @moduledoc """
  Decodes one RFC 5322 message into a part tree.

  The decoder handles header unfolding, RFC 2047 encoded words, RFC 2231
  parameter values, the standard transfer encodings, nested multipart bodies,
  and `message/rfc822` parts. Text bodies stay raw bytes here; `Charset`
  converts them when the caller projects the message.
  """

  alias Ankole.Plugins.EmailAdapter.Charset

  defmodule Part do
    @moduledoc false

    defstruct type: "text",
              subtype: "plain",
              params: %{},
              disposition: nil,
              disposition_params: %{},
              headers: [],
              body: nil,
              parts: nil

    @type t :: %__MODULE__{
            type: String.t(),
            subtype: String.t(),
            params: %{String.t() => String.t()},
            disposition: String.t() | nil,
            disposition_params: %{String.t() => String.t()},
            headers: [{String.t(), String.t()}],
            body: binary() | nil,
            parts: [t()] | nil
          }
  end

  @encoded_word ~r/=\?([^?\s]+)\?([BbQq])\?([^?\s]*)\?=/

  @spec parse(binary()) :: Part.t()
  def parse(raw) when is_binary(raw) do
    {headers, body} = split_headers(raw)
    build_part(headers, body)
  end

  @doc "Parses only the header block, for a message fetched without its body."
  @spec parse_headers(binary()) :: [{String.t(), String.t()}]
  def parse_headers(raw) when is_binary(raw) do
    {headers, _body} = split_headers(raw)
    headers
  end

  @doc "Returns the first value of one header, unfolded, without RFC 2047 decoding."
  @spec header(Part.t() | [{String.t(), String.t()}], String.t()) :: String.t() | nil
  def header(%Part{headers: headers}, name), do: header(headers, name)

  def header(headers, name) when is_list(headers) do
    wanted = String.downcase(name)

    Enum.find_value(headers, fn {key, value} -> if key == wanted, do: value end)
  end

  @spec headers(Part.t() | [{String.t(), String.t()}], String.t()) :: [String.t()]
  def headers(%Part{headers: headers}, name), do: headers(headers, name)

  def headers(headers, name) when is_list(headers) do
    wanted = String.downcase(name)
    for {key, value} <- headers, key == wanted, do: value
  end

  @doc "Decodes RFC 2047 encoded words in one header value into UTF-8 text."
  @spec decode_text(String.t() | nil) :: String.t() | nil
  def decode_text(nil), do: nil

  def decode_text(value) when is_binary(value) do
    value
    |> collapse_between_encoded_words()
    |> then(
      &Regex.replace(@encoded_word, &1, fn _all, charset, encoding, payload ->
        decode_encoded_word(charset, encoding, payload)
      end)
    )
    |> Charset.to_utf8(nil)
    |> elem(1)
    |> String.trim()
  end

  @doc """
  Replaces every encoded word with an opaque placeholder token.

  An address header must be parsed before its encoded words are decoded
  (RFC 2047 section 6.2): decoded text can contain `<`, `>`, `,`, or `@` and
  would otherwise change which mailbox the header names. The placeholder is a
  plain atom, so the structure parser cannot see the encoded content, and
  `restore_encoded_words/2` puts the decoded text back into display names.
  """
  @spec mask_encoded_words(String.t()) :: {String.t(), %{String.t() => String.t()}}
  def mask_encoded_words(value) when is_binary(value) do
    collapsed = collapse_between_encoded_words(value)

    words =
      @encoded_word
      |> Regex.scan(collapsed)
      |> Enum.with_index(1)
      |> Map.new(fn {[_all, charset, encoding, payload], index} ->
        {"EW__#{index}__", decode_encoded_word(charset, encoding, payload)}
      end)

    masked =
      Enum.reduce(1..map_size(words)//1, collapsed, fn index, acc ->
        Regex.replace(@encoded_word, acc, "EW__#{index}__", global: false)
      end)

    {masked, words}
  end

  @spec restore_encoded_words(String.t() | nil, %{String.t() => String.t()}) :: String.t() | nil
  def restore_encoded_words(nil, _words), do: nil

  def restore_encoded_words(text, words) when is_binary(text) do
    Regex.replace(~r/EW__\d+__/, text, fn placeholder -> Map.get(words, placeholder, "") end)
  end

  @doc "Splits `type/subtype; a=b` into its parts with decoded parameters."
  @spec parse_content_type(String.t() | nil) :: {String.t(), String.t(), map()}
  def parse_content_type(nil), do: {"text", "plain", %{"charset" => "us-ascii"}}

  def parse_content_type(value) do
    {media, params} = split_params(value)

    case String.split(String.downcase(media), "/", parts: 2) do
      [type, subtype] when type != "" and subtype != "" -> {type, subtype, params}
      _invalid -> {"text", "plain", params}
    end
  end

  @spec parse_disposition(String.t() | nil) :: {String.t() | nil, map()}
  def parse_disposition(nil), do: {nil, %{}}

  def parse_disposition(value) do
    {disposition, params} = split_params(value)
    {String.downcase(disposition), params}
  end

  @spec decode_body(binary(), String.t() | nil) :: binary()
  def decode_body(body, nil), do: body

  def decode_body(body, encoding) do
    case encoding |> String.trim() |> String.downcase() do
      "base64" -> decode_base64(body)
      "quoted-printable" -> decode_quoted_printable(body)
      _plain -> body
    end
  end

  @spec decode_quoted_printable(binary()) :: binary()
  def decode_quoted_printable(body) do
    body
    |> String.replace(~r/[ \t]+(\r?\n)/, "\\1")
    |> String.replace(~r/=\r?\n/, "")
    |> then(
      &Regex.replace(~r/=([0-9A-Fa-f]{2})/, &1, fn _all, hex -> <<String.to_integer(hex, 16)>> end)
    )
  end

  defp decode_base64(body) do
    cleaned = String.replace(body, ~r/[^A-Za-z0-9+\/=]/, "")

    case Base.decode64(cleaned, padding: false) do
      {:ok, decoded} -> decoded
      :error -> cleaned |> String.trim_trailing("=") |> Base.decode64!(padding: false)
    end
  rescue
    _exception -> ""
  end

  defp build_part(headers, body) do
    {type, subtype, params} = parse_content_type(header(headers, "content-type"))
    {disposition, disposition_params} = parse_disposition(header(headers, "content-disposition"))

    part = %Part{
      type: type,
      subtype: subtype,
      params: params,
      disposition: disposition,
      disposition_params: disposition_params,
      headers: headers
    }

    cond do
      type == "multipart" and is_binary(params["boundary"]) ->
        %{part | parts: split_multipart(body, params["boundary"])}

      type == "message" and subtype == "rfc822" ->
        %{part | body: decode_body(body, header(headers, "content-transfer-encoding"))}

      true ->
        %{part | body: decode_body(body, header(headers, "content-transfer-encoding"))}
    end
  end

  defp split_multipart(body, boundary) do
    delimiter = "--" <> boundary

    body
    |> String.split(~r/(?:^|\r?\n)#{Regex.escape(delimiter)}/)
    |> Enum.drop(1)
    |> Enum.reduce_while([], fn segment, parts ->
      cond do
        String.starts_with?(segment, "--") ->
          {:halt, parts}

        true ->
          content = segment |> String.replace(~r/\A[^\r\n]*\r?\n/, "", global: false)
          {headers, part_body} = split_headers(content)
          {:cont, [build_part(headers, part_body) | parts]}
      end
    end)
    |> Enum.reverse()
  end

  defp split_headers(raw) do
    {header_block, body} =
      case :binary.match(raw, ["\r\n\r\n", "\n\n"]) do
        {offset, length} ->
          {binary_part(raw, 0, offset),
           binary_part(raw, offset + length, byte_size(raw) - offset - length)}

        :nomatch ->
          if String.starts_with?(raw, ["\r\n", "\n"]), do: {"", raw}, else: {raw, ""}
      end

    {unfold_headers(header_block), body}
  end

  defp unfold_headers(""), do: []

  defp unfold_headers(block) do
    block
    |> String.split(~r/\r?\n/)
    |> Enum.reduce([], fn
      <<space, rest::binary>>, [{name, value} | acc] when space in [?\s, ?\t] ->
        [{name, value <> " " <> String.trim(rest)} | acc]

      line, acc ->
        case String.split(line, ":", parts: 2) do
          [name, value] when name != "" ->
            [{String.downcase(String.trim(name)), String.trim(value)} | acc]

          _invalid ->
            acc
        end
    end)
    |> Enum.reverse()
  end

  # Whitespace between two adjacent encoded words is not part of the text.
  defp collapse_between_encoded_words(value) do
    Regex.replace(~r/(\?=)[ \t\r\n]+(=\?)/, value, "\\1\\2")
  end

  defp decode_encoded_word(charset, encoding, payload) do
    charset = charset |> String.split("*", parts: 2) |> List.first()

    bytes =
      case String.upcase(encoding) do
        "B" -> decode_base64(payload)
        "Q" -> payload |> String.replace("_", " ") |> decode_quoted_printable()
      end

    case Charset.to_utf8(bytes, charset) do
      {:ok, text} -> text
      {:error, _reason} -> Charset.ascii_only(bytes)
    end
  end

  # Splits `value; name=value; name*=utf-8''...` and reassembles RFC 2231
  # continuations (`name*0*`, `name*1`) in order.
  defp split_params(value) do
    [head | pairs] = split_semicolons(value)

    params =
      pairs
      |> Enum.flat_map(fn pair ->
        case String.split(pair, "=", parts: 2) do
          [name, raw] -> [{String.downcase(String.trim(name)), unquote_value(String.trim(raw))}]
          _invalid -> []
        end
      end)
      |> assemble_rfc2231()

    {String.trim(head), params}
  end

  defp split_semicolons(value) do
    value
    |> String.to_charlist()
    |> Enum.reduce({[], [], false}, fn
      ?", {current, acc, quoted?} -> {[?" | current], acc, not quoted?}
      ?;, {current, acc, false} -> {[], [List.to_string(Enum.reverse(current)) | acc], false}
      char, {current, acc, quoted?} -> {[char | current], acc, quoted?}
    end)
    |> then(fn {current, acc, _quoted?} ->
      Enum.reverse([List.to_string(Enum.reverse(current)) | acc])
    end)
  end

  defp unquote_value("\"" <> rest) do
    rest |> String.trim_trailing("\"") |> String.replace(~r/\\(.)/, "\\1")
  end

  defp unquote_value(value), do: value

  # An extended value (`name*` or the `name*0*` segments) wins over a plain
  # `name`; only the numbered segments concatenate.
  defp assemble_rfc2231(pairs) do
    pairs
    |> Enum.group_by(fn {name, _value} -> name |> String.split("*") |> List.first() end)
    |> Enum.map(fn {base, entries} ->
      segments =
        entries
        |> Enum.filter(fn {name, _value} -> section_index(name) >= 0 end)
        |> Enum.sort_by(fn {name, _value} -> section_index(name) end)

      extended = Enum.find(entries, fn {name, _value} -> name == base <> "*" end)
      plain = Enum.find(entries, fn {name, _value} -> name == base end)

      value =
        cond do
          segments != [] ->
            decode_segments(segments)

          extended != nil ->
            decode_rfc2231(elem(extended, 1))

          plain != nil ->
            decode_text(elem(plain, 1))
        end

      {base, value}
    end)
    |> Map.new()
  end

  defp section_index(name) do
    case Regex.run(~r/\*(\d+)\*?\z/, name) do
      [_all, index] -> String.to_integer(index)
      nil -> -1
    end
  end

  # Each segment carries its own encoding mark: a `*` segment is
  # percent-encoded and the first one may name the charset, a plain segment is
  # literal text (RFC 2231 section 4.1).
  defp decode_segments(segments) do
    {charset, bytes} =
      Enum.reduce(segments, {nil, ""}, fn {name, value}, {charset, acc} ->
        cond do
          not String.ends_with?(name, "*") ->
            {charset, acc <> value}

          is_nil(charset) ->
            {segment_charset, encoded} = split_charset(value)
            {segment_charset, acc <> percent_decode(encoded)}

          true ->
            {charset, acc <> percent_decode(value)}
        end
      end)

    to_text(bytes, charset || "utf-8")
  end

  defp decode_rfc2231(value) do
    {charset, encoded} = split_charset(value)
    to_text(percent_decode(encoded), charset)
  end

  defp split_charset(value) do
    case String.split(value, "'", parts: 3) do
      [charset, _language, encoded] -> {charset, encoded}
      _plain -> {"utf-8", value}
    end
  end

  defp percent_decode(encoded) do
    Regex.replace(~r/%([0-9A-Fa-f]{2})/, encoded, fn _all, hex ->
      <<String.to_integer(hex, 16)>>
    end)
  end

  defp to_text(bytes, charset) do
    case Charset.to_utf8(bytes, charset) do
      {:ok, text} -> text
      {:error, _reason} -> Charset.ascii_only(bytes)
    end
  end
end
