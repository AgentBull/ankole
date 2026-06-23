defmodule FeishuOpenAPI.WS.Frame do
  @moduledoc """
  Encodes and decodes Feishu's `pbbp2.Frame` Protobuf envelope used over the
  WebSocket transport. Wire layout (field numbers, wire types):

    1. `SeqID` — uint64, varint
    2. `LogID` — uint64, varint
    3. `service` — int32, varint
    4. `method` — int32, varint (0 = control, 1 = data)
    5. `headers` — repeated `Header { key, value }`, length-delimited
    6. `payload_encoding` — string, length-delimited
    7. `payload_type` — string, length-delimited
    8. `payload` — bytes, length-delimited
    9. `LogIDNew` — string, length-delimited

  Only these field numbers are recognized; unknown fields are skipped for
  forward-compat. `headers` are exposed as a `[{key, value}]` list.
  """

  import Bitwise

  @type t :: %__MODULE__{
          seq_id: non_neg_integer(),
          log_id: non_neg_integer(),
          service: integer(),
          method: integer(),
          headers: [{String.t(), String.t()}],
          payload_encoding: String.t(),
          payload_type: String.t(),
          payload: binary(),
          log_id_new: String.t()
        }

  defstruct seq_id: 0,
            log_id: 0,
            service: 0,
            method: 0,
            headers: [],
            payload_encoding: "",
            payload_type: "",
            payload: "",
            log_id_new: ""

  # Wire types
  @varint 0
  @fixed64 1
  @bytes 2
  @fixed32 5

  @doc "Encode a `%Frame{}` into its wire binary form."
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = f) do
    [
      if(f.seq_id != 0, do: varint_field(1, f.seq_id), else: []),
      if(f.log_id != 0, do: varint_field(2, f.log_id), else: []),
      if(f.service != 0, do: varint_field(3, f.service), else: []),
      varint_field(4, f.method),
      Enum.map(f.headers, &encode_header/1),
      bytes_field_optional(6, f.payload_encoding),
      bytes_field_optional(7, f.payload_type),
      bytes_field_optional(8, f.payload),
      bytes_field_optional(9, f.log_id_new)
    ]
    |> IO.iodata_to_binary()
  end

  @doc "Decode a binary frame. Returns `{:ok, %Frame{}}` or `{:error, reason}`."
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(bin) when is_binary(bin) do
    try do
      frame = decode_fields(bin, %__MODULE__{})
      {:ok, %{frame | headers: Enum.reverse(frame.headers)}}
    rescue
      e -> {:error, e}
    catch
      {:decode_error, reason} -> {:error, reason}
    end
  end

  @doc """
  Look up a header value by key. Matches the first occurrence.
  """
  @spec get_header(t(), String.t()) :: String.t() | nil
  def get_header(%__MODULE__{headers: hs}, key) when is_binary(key) do
    Enum.find_value(hs, fn {k, v} -> if k == key, do: v end)
  end

  @doc "Convenience: the `type` header (`event` / `card` / `ping` / `pong`)."
  @spec type(t()) :: String.t() | nil
  def type(frame), do: get_header(frame, "type")

  @doc "Convenience: the `message_id` header for fragmentation support."
  @spec message_id(t()) :: String.t() | nil
  def message_id(frame), do: get_header(frame, "message_id")

  @doc "Convenience: fragmentation count (headers `sum` and `seq`)."
  @spec fragmentation(t()) :: {integer(), integer()} | nil
  def fragmentation(frame) do
    with sum when is_binary(sum) <- get_header(frame, "sum"),
         seq when is_binary(seq) <- get_header(frame, "seq"),
         {s, ""} <- Integer.parse(sum),
         {i, ""} <- Integer.parse(seq) do
      {s, i}
    else
      _ -> nil
    end
  end

  # --- decode internals ---------------------------------------------------

  defp decode_fields(<<>>, frame), do: frame

  defp decode_fields(bin, frame) do
    {tag, rest} = read_varint(bin)
    field_num = tag >>> 3
    wire_type = tag &&& 0x07
    {value, rest} = read_value(wire_type, rest)
    decode_fields(rest, apply_field(frame, field_num, value))
  end

  defp apply_field(f, 1, {:varint, v}), do: %{f | seq_id: v}
  defp apply_field(f, 2, {:varint, v}), do: %{f | log_id: v}
  defp apply_field(f, 3, {:varint, v}), do: %{f | service: to_int32(v)}
  defp apply_field(f, 4, {:varint, v}), do: %{f | method: to_int32(v)}

  defp apply_field(f, 5, {:bytes, data}) do
    {key, value} = decode_header_message(data)
    %{f | headers: [{key, value} | f.headers]}
  end

  defp apply_field(f, 6, {:bytes, data}), do: %{f | payload_encoding: data}
  defp apply_field(f, 7, {:bytes, data}), do: %{f | payload_type: data}
  defp apply_field(f, 8, {:bytes, data}), do: %{f | payload: data}
  defp apply_field(f, 9, {:bytes, data}), do: %{f | log_id_new: data}
  defp apply_field(f, _num, _value), do: f

  defp decode_header_message(bin), do: decode_header_fields(bin, "", "")

  defp decode_header_fields(<<>>, key, value), do: {key, value}

  defp decode_header_fields(bin, key, value) do
    {tag, rest} = read_varint(bin)
    field_num = tag >>> 3
    wire_type = tag &&& 0x07
    {v, rest} = read_value(wire_type, rest)

    case {field_num, v} do
      {1, {:bytes, b}} -> decode_header_fields(rest, b, value)
      {2, {:bytes, b}} -> decode_header_fields(rest, key, b)
      _ -> decode_header_fields(rest, key, value)
    end
  end

  defp read_value(@varint, bin), do: {varint_tagged(bin), elem(read_varint(bin), 1)}

  defp read_value(@bytes, bin) do
    {len, rest} = read_varint(bin)

    case rest do
      <<data::binary-size(^len), rest::binary>> -> {{:bytes, data}, rest}
      _ -> throw({:decode_error, :truncated_bytes})
    end
  end

  defp read_value(@fixed64, <<v::little-64, rest::binary>>), do: {{:fixed64, v}, rest}
  defp read_value(@fixed32, <<v::little-32, rest::binary>>), do: {{:fixed32, v}, rest}
  defp read_value(wt, _), do: throw({:decode_error, {:unknown_wire_type, wt}})

  defp varint_tagged(bin) do
    {v, _} = read_varint(bin)
    {:varint, v}
  end

  defp read_varint(bin), do: read_varint(bin, 0, 0)

  defp read_varint(<<1::1, chunk::7, rest::binary>>, shift, acc) do
    read_varint(rest, shift + 7, acc ||| chunk <<< shift)
  end

  defp read_varint(<<0::1, chunk::7, rest::binary>>, shift, acc) do
    {acc ||| chunk <<< shift, rest}
  end

  defp read_varint(<<>>, _shift, _acc), do: throw({:decode_error, :truncated_varint})

  # --- encode internals ---------------------------------------------------

  defp varint_field(field_num, value) do
    [encode_varint(field_num <<< 3 ||| @varint), encode_varint(value)]
  end

  defp bytes_field_optional(_num, ""), do: []
  defp bytes_field_optional(num, value), do: bytes_field(num, value)

  defp bytes_field(field_num, value) when is_binary(value) do
    [
      encode_varint(field_num <<< 3 ||| @bytes),
      encode_varint(byte_size(value)),
      value
    ]
  end

  defp encode_header({key, value}) when is_binary(key) and is_binary(value) do
    inner =
      IO.iodata_to_binary([
        bytes_field(1, key),
        bytes_field(2, value)
      ])

    bytes_field(5, inner)
  end

  defp encode_varint(v) when v < 0x80, do: <<v>>

  defp encode_varint(v) do
    <<1::1, v &&& 0x7F::7>> <> encode_varint(v >>> 7)
  end

  defp to_int32(v) when v >= 0x80000000, do: v - 0x100000000
  defp to_int32(v), do: v
end
