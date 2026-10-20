defmodule FeishuOpenAPI.WS.FrameTest do
  use ExUnit.Case, async: true

  alias FeishuOpenAPI.WS.Frame

  describe "encode/decode round-trip" do
    test "preserves all fields" do
      frame = %Frame{
        seq_id: 42,
        log_id: 123_456_789,
        service: 17,
        method: 1,
        headers: [{"type", "event"}, {"message_id", "abc-123"}, {"sum", "1"}, {"seq", "0"}],
        payload_encoding: "json",
        payload_type: "application/json",
        payload: ~s({"hello":"world"}),
        log_id_new: "new-log-id"
      }

      bin = Frame.encode(frame)
      assert {:ok, decoded} = Frame.decode(bin)

      assert decoded.seq_id == frame.seq_id
      assert decoded.log_id == frame.log_id
      assert decoded.service == frame.service
      assert decoded.method == frame.method
      assert decoded.headers == frame.headers
      assert decoded.payload_encoding == frame.payload_encoding
      assert decoded.payload_type == frame.payload_type
      assert decoded.payload == frame.payload
      assert decoded.log_id_new == frame.log_id_new
    end

    test "a minimal ping includes the proto2 required zero-valued scalars" do
      frame = %Frame{method: 0, headers: [{"type", "ping"}]}
      encoded = Frame.encode(frame)

      # Matches the official SDK's generated pbbp2 encoder: fields 1..4 are
      # required and therefore emitted even when every scalar is zero.
      assert encoded ==
               <<8, 0, 16, 0, 24, 0, 32, 0, 42, 12, 10, 4, "type", 18, 4, "ping">>

      assert {:ok, decoded} = Frame.decode(encoded)
      assert Frame.type(decoded) == "ping"
      assert decoded.method == 0
    end
  end

  describe "helpers" do
    test "get_header/2 returns nil when the key is absent" do
      assert Frame.get_header(%Frame{headers: [{"type", "event"}]}, "message_id") == nil
    end

    test "fragmentation/1 parses numeric sum + seq" do
      f = %Frame{headers: [{"sum", "3"}, {"seq", "1"}]}
      assert Frame.fragmentation(f) == {3, 1}
    end

    test "fragmentation/1 returns nil when headers are missing" do
      assert Frame.fragmentation(%Frame{headers: []}) == nil
    end
  end

  describe "decode/1 error handling" do
    test "truncated bytes field" do
      # varint tag 0x42 = field 8 (payload), wire type 2 (bytes); length 5 but data is 2 bytes
      assert {:error, :truncated_bytes} = Frame.decode(<<0x42, 5, 1, 2>>)
    end
  end
end
