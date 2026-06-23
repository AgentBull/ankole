defmodule FeishuOpenAPI.WS.ProtocolTest do
  use ExUnit.Case, async: true

  alias FeishuOpenAPI.WS.Protocol

  test "service_id_from_url/1 parses the service_id query param" do
    url = "wss://example.com/ws?device_id=abc&service_id=42"
    assert Protocol.service_id_from_url(url) == 42
  end

  test "config_from_map/1 supports server-style uppercase keys" do
    cfg =
      Protocol.config_from_map(%{
        "PingInterval" => 10,
        "ReconnectInterval" => 20,
        "ReconnectNonce" => 3,
        "ReconnectCount" => -1
      })

    assert cfg == %{
             ping_interval_s: 10,
             reconnect_interval_s: 20,
             reconnect_nonce_s: 3,
             reconnect_count: -1
           }
  end

  test "config_from_map/1 supports lowercase keys too" do
    cfg =
      Protocol.config_from_map(%{
        "ping_interval" => "11",
        "reconnect_interval" => 21,
        "reconnect_nonce" => 4,
        "reconnect_count" => 5
      })

    assert cfg == %{
             ping_interval_s: 11,
             reconnect_interval_s: 21,
             reconnect_nonce_s: 4,
             reconnect_count: 5
           }
  end

  test "encode_ws_response/1 emits the Go-style response envelope" do
    assert {:ok, encoded} = Protocol.encode_ws_response({:ok, :no_handler})
    assert {:ok, decoded} = Torque.decode(encoded)

    assert decoded == %{"code" => 200}
  end

  test "encode_ws_response/1 maps handler failures to retryable transport errors" do
    assert {:ok, encoded} = Protocol.encode_ws_response({:error, {:handler_failed, :boom}})
    assert {:ok, decoded} = Torque.decode(encoded)

    assert decoded == %{"code" => 500}
  end

  test "encode_ws_response/1 base64-encodes callback data" do
    callback_response = %{"toast" => %{"type" => "success", "content" => "ok"}}

    assert {:ok, encoded} = Protocol.encode_ws_response({:ok, callback_response})
    assert {:ok, decoded} = Torque.decode(encoded)

    assert decoded["code"] == 200
    assert Base.decode64!(decoded["data"]) == Torque.encode!(callback_response)
  end

  test "classify_handshake/3 treats auth failures as fatal" do
    headers = %{
      "Handshake-Status" => "514",
      "Handshake-Msg" => "auth failed",
      "Handshake-Autherrcode" => "1000040350"
    }

    assert {:fatal, {:handshake_error, 514, "auth failed"}} =
             Protocol.classify_handshake(400, headers, :boom)
  end
end
