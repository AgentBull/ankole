defmodule FeishuOpenAPI.Event.EnvelopeTest do
  use ExUnit.Case, async: true

  alias FeishuOpenAPI.Event.Envelope

  describe "decode/2" do
    test "passes plaintext JSON through untouched" do
      body = ~s({"schema":"2.0","header":{"event_type":"im.message.receive_v1"},"event":{}})
      assert {:ok, %{"schema" => "2.0"}} = Envelope.decode(body)
    end

    test "requires encrypt_key when the body is encrypted" do
      body = ~s({"encrypt":"somebase64=="})
      assert Envelope.decode(body) == {:error, :encrypt_key_required}
    end

    test "decrypts an encrypted payload" do
      plain = ~s({"schema":"2.0","header":{"event_type":"test"},"event":{}})
      {:ok, cipher} = FeishuOpenAPI.Crypto.encrypt(plain, "k")
      body = Torque.encode!(%{encrypt: cipher})

      assert {:ok, decoded} = Envelope.decode(body, "k")
      assert decoded["schema"] == "2.0"
    end

    test "returns JSON decode errors" do
      assert {:error, reason} = Envelope.decode("not json")
      assert is_binary(reason)
    end
  end

  describe "event_type/1" do
    test "P2 envelope prefers header.event_type" do
      assert Envelope.event_type(%{
               "schema" => "2.0",
               "header" => %{"event_type" => "im.message.receive_v1"}
             }) == "im.message.receive_v1"
    end

    test "P1 event_callback uses event.type" do
      assert Envelope.event_type(%{
               "type" => "event_callback",
               "event" => %{"type" => "message"}
             }) == "message"
    end

    test "top-level type is used for challenge" do
      assert Envelope.event_type(%{"type" => "url_verification"}) == "url_verification"
    end

    test "unknown shape returns nil" do
      assert Envelope.event_type(%{}) == nil
    end
  end

  describe "challenge helpers" do
    test "challenge?/1 and challenge/1 extract the echo value" do
      env = %{"type" => "url_verification", "challenge" => "abc", "token" => "t"}
      assert Envelope.challenge?(env)
      assert Envelope.challenge(env) == "abc"
    end

    test "challenge?/1 is false for non-verification envelopes" do
      refute Envelope.challenge?(%{"type" => "event_callback"})
    end
  end
end
