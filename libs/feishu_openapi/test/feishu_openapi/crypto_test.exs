defmodule FeishuOpenAPI.CryptoTest do
  use ExUnit.Case, async: true

  alias FeishuOpenAPI.Crypto

  describe "event_signature/4" do
    test "matches the Go SDK formula (SHA256 of ts||nonce||key||body, hex-lowercase)" do
      expected =
        :crypto.hash(:sha256, "1711111" <> "nonce1" <> "key1" <> "{\"a\":1}")
        |> Base.encode16(case: :lower)

      assert Crypto.event_signature("1711111", "nonce1", "key1", "{\"a\":1}") == expected
    end

    test "verify_event accepts the signature it just produced" do
      sig = Crypto.event_signature("1", "2", "k", "body")
      assert Crypto.verify_event("1", "2", "k", "body", sig) == :ok
    end

    test "verify_event rejects a tampered body" do
      sig = Crypto.event_signature("1", "2", "k", "body")
      assert Crypto.verify_event("1", "2", "k", "tampered", sig) == {:error, :bad_signature}
    end
  end

  describe "card_signature/4" do
    test "uses SHA1 (not SHA256)" do
      expected =
        :crypto.hash(:sha, "1711111" <> "nonce1" <> "verification_token" <> "{}")
        |> Base.encode16(case: :lower)

      assert Crypto.card_signature("1711111", "nonce1", "verification_token", "{}") == expected
    end
  end

  describe "encrypt / decrypt round trip" do
    test "plaintext is recovered exactly" do
      secret = "encrypt_key_example"
      plaintext = ~s({"msg":"hello 世界","n":42})

      {:ok, ciphertext} = Crypto.encrypt(plaintext, secret)
      {:ok, decoded} = Crypto.decrypt(ciphertext, secret)

      assert decoded == plaintext
    end

    test "tampered ciphertext with invalid PKCS7 padding is rejected" do
      {:ok, ct} = Crypto.encrypt("{}", "right")
      raw = Base.decode64!(ct)
      size = byte_size(raw) - 1
      <<head::binary-size(^size), last>> = raw
      tampered = Base.encode64(head <> <<Bitwise.bxor(last, 0xFF)>>)

      assert {:error, :invalid_padding} = Crypto.decrypt(tampered, "right")
    end

    test "malformed base64 is rejected" do
      assert {:error, :invalid_base64} = Crypto.decrypt("!!!!!", "k")
    end

    test "ciphertext shorter than one AES block is rejected" do
      short = Base.encode64(<<1, 2, 3>>)
      assert {:error, :cipher_too_short} = Crypto.decrypt(short, "k")
    end
  end
end
