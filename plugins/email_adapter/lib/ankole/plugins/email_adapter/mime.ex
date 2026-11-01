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
  plain atom with a per-call random token, so the structure parser cannot see
  the encoded content and literal header text cannot collide with it;
  `restore_encoded_words/2` puts the decoded text back into display names.
  """
  @spec mask_encoded_words(String.t()) :: {String.t(), %{String.t() => String.t()}}
  def mask_encoded_words(value) when is_binary(value) do
    collapsed = collapse_between_encoded_words(value)
    token = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    words =
      @encoded_word
      |> Regex.scan(collapsed)
      |> Enum.with_index(1)
      |> Map.new(fn {[_all, charset, encoding, payload], index} ->
        {"EW#{token}X#{index}X", decode_encoded_word(charset, encoding, payload)}
      end)

    masked =
      Enum.reduce(1..map_size(words)//1, collapsed, fn index, acc ->
        Regex.replace(@encoded_word, acc, "EW#{token}X#{index}X", global: false)
      end)

    {masked, words}
  end

  @spec restore_encoded_words(String.t() | nil, %{String.t() => String.t()}) :: String.t() | nil
  def restore_encoded_words(nil, _words), do: nil

  def restore_encoded_words(text, words) when is_binary(text) do
    Enum.reduce(words, text, fn {placeholder, decoded}, acc ->
      String.replace(acc, placeholder, decoded)
    end)
  end

  # Splits `type/subtype; a=b` into its parts with decoded parameters.
  @spec parse_content_type(String.t() | nil) :: {String.t(), String.t(), map()}
  defp parse_content_type(nil), do: {"text", "plain", %{"charset" => "us-ascii"}}

  defp parse_content_type(value) do
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
  defp decode_body(body, nil), do: body

  defp decode_body(body, encoding) do
    case encoding |> String.trim() |> String.downcase() do
      "base64" -> decode_base64(body)
      "quoted-printable" -> decode_quoted_printable(body)
      _plain -> body
    end
  end

  @spec decode_quoted_printable(binary()) :: binary()
  defp decode_quoted_printable(body) do
    body
    |> :binary.split("\n", [:global])
    |> unfold_qp_lines(<<>>)
    |> decode_qp_hex(<<>>)
  end

  defp unfold_qp_lines([last], acc), do: <<acc::binary, last::binary>>

  defp unfold_qp_lines([line | rest], acc) do
    {content, ending} =
      if byte_size(line) > 0 and :binary.last(line) == ?\r do
        {binary_part(line, 0, byte_size(line) - 1), "\r\n"}
      else
        {line, "\n"}
      end

    trimmed = trim_trailing_lwsp(content, byte_size(content))

    if byte_size(trimmed) > 0 and :binary.last(trimmed) == ?= do
      soft = binary_part(trimmed, 0, byte_size(trimmed) - 1)
      unfold_qp_lines(rest, <<acc::binary, soft::binary>>)
    else
      unfold_qp_lines(rest, <<acc::binary, trimmed::binary, ending::binary>>)
    end
  end

  defp trim_trailing_lwsp(bin, len) when len > 0 do
    if :binary.at(bin, len - 1) in [?\s, ?\t],
      do: trim_trailing_lwsp(bin, len - 1),
      else: binary_part(bin, 0, len)
  end

  defp trim_trailing_lwsp(_bin, 0), do: <<>>

  defp decode_qp_hex(<<>>, acc), do: acc

  defp decode_qp_hex(bin, acc) do
    case :binary.match(bin, "=") do
      :nomatch ->
        <<acc::binary, bin::binary>>

      {offset, 1} ->
        prefix = binary_part(bin, 0, offset)
        tail = binary_part(bin, offset, byte_size(bin) - offset)
        decode_qp_escape(tail, <<acc::binary, prefix::binary>>)
    end
  end

  defp decode_qp_escape(<<?=, h1, h2, rest::binary>>, acc)
       when (h1 in ?0..?9 or h1 in ?A..?F or h1 in ?a..?f) and
              (h2 in ?0..?9 or h2 in ?A..?F or h2 in ?a..?f) do
    byte = hex_nibble(h1) * 16 + hex_nibble(h2)
    decode_qp_hex(rest, <<acc::binary, byte>>)
  end

  defp decode_qp_escape(<<?=, rest::binary>>, acc) do
    decode_qp_hex(rest, <<acc::binary, ?=>>)
  end

  defp hex_nibble(c) when c in ?0..?9, do: c - ?0
  defp hex_nibble(c) when c in ?A..?F, do: c - ?A + 10
  defp hex_nibble(c) when c in ?a..?f, do: c - ?a + 10

  defp decode_base64(body) do
    case Base.decode64(body, ignore: :whitespace, padding: false) do
      {:ok, decoded} ->
        decoded

      :error ->
        cleaned = String.replace(body, ~r/[^A-Za-z0-9+\/=]/, "")

        case Base.decode64(cleaned, padding: false) do
          {:ok, decoded} -> decoded
          :error -> cleaned |> String.trim_trailing("=") |> Base.decode64!(padding: false)
        end
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
    delim_len = byte_size(delimiter)

    boundaries =
      body
      |> :binary.matches(delimiter)
      |> collect_line_boundaries(body, delim_len, 0, [])

    collect_multipart_parts(boundaries, body, [])
  end

  defp collect_line_boundaries([], _body, _delim_len, _cursor, acc), do: Enum.reverse(acc)

  defp collect_line_boundaries([{0, _len} | rest], body, delim_len, 0, acc) do
    if valid_boundary_tail?(body, delim_len) do
      collect_line_boundaries(rest, body, delim_len, delim_len, [{0, delim_len} | acc])
    else
      collect_line_boundaries(rest, body, delim_len, 0, acc)
    end
  end

  defp collect_line_boundaries([{pos, _len} | rest], body, delim_len, cursor, acc) do
    after_delim = pos + delim_len

    cond do
      pos >= 2 and pos - 2 >= cursor and binary_part(body, pos - 2, 2) == "\r\n" and
          valid_boundary_tail?(body, after_delim) ->
        collect_line_boundaries(rest, body, delim_len, after_delim, [{pos - 2, after_delim} | acc])

      pos >= 1 and pos - 1 >= cursor and :binary.at(body, pos - 1) == ?\n and
          valid_boundary_tail?(body, after_delim) ->
        collect_line_boundaries(rest, body, delim_len, after_delim, [{pos - 1, after_delim} | acc])

      true ->
        collect_line_boundaries(rest, body, delim_len, cursor, acc)
    end
  end

  defp valid_boundary_tail?(body, pos) do
    size = byte_size(body)

    idx =
      if pos + 2 <= size and binary_part(body, pos, 2) == "--" do
        pos + 2
      else
        pos
      end

    only_lwsp_to_eol?(body, idx, size)
  end

  defp only_lwsp_to_eol?(_body, idx, size) when idx >= size, do: true

  defp only_lwsp_to_eol?(body, idx, size) do
    case :binary.at(body, idx) do
      b when b in [?\s, ?\t] -> only_lwsp_to_eol?(body, idx + 1, size)
      ?\n -> true
      ?\r -> idx + 1 >= size or :binary.at(body, idx + 1) == ?\n
      _other -> false
    end
  end

  defp collect_multipart_parts([], _body, parts), do: Enum.reverse(parts)

  defp collect_multipart_parts([{_start, after_delim} | rest], body, parts) do
    next_start =
      case rest do
        [{start, _next_after} | _] -> start
        [] -> byte_size(body)
      end

    segment_len = next_start - after_delim

    if segment_len >= 2 and binary_part(body, after_delim, 2) == "--" do
      Enum.reverse(parts)
    else
      content = strip_boundary_line(body, after_delim, next_start, after_delim)
      {headers, part_body} = split_headers(content)
      collect_multipart_parts(rest, body, [build_part(headers, part_body) | parts])
    end
  end

  defp strip_boundary_line(body, start, limit, idx) when idx < limit do
    case :binary.at(body, idx) do
      ?\n ->
        binary_part(body, idx + 1, limit - (idx + 1))

      ?\r ->
        if idx + 1 < limit and :binary.at(body, idx + 1) == ?\n do
          binary_part(body, idx + 2, limit - (idx + 2))
        else
          binary_part(body, start, limit - start)
        end

      _other ->
        strip_boundary_line(body, start, limit, idx + 1)
    end
  end

  defp strip_boundary_line(body, start, limit, _idx), do: binary_part(body, start, limit - start)

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

          true ->
            nil
        end

      {base, value}
    end)
    |> Enum.reject(fn {_base, value} -> is_nil(value) end)
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
