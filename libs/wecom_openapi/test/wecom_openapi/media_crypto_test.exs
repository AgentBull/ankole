defmodule WeComOpenAPI.MediaCryptoTest do
  use ExUnit.Case, async: true

  alias WeComOpenAPI.MediaCrypto

  defp encrypt(plaintext, key) do
    pad = 32 - rem(byte_size(plaintext), 32)
    pad = if pad == 0, do: 32, else: pad
    padded = plaintext <> :binary.copy(<<pad>>, pad)
    iv = binary_part(key, 0, 16)
    :crypto.crypto_one_time(:aes_256_cbc, key, iv, padded, true)
  end

  test "decrypts AES-256-CBC media with the unpadded-Base64 aeskey" do
    key = :crypto.strong_rand_bytes(32)
    aeskey = key |> Base.encode64() |> String.trim_trailing("=")
    plaintext = "png-bytes-" <> :crypto.strong_rand_bytes(100)

    assert {:ok, ^plaintext} = MediaCrypto.decrypt(encrypt(plaintext, key), aeskey)
  end

  test "rejects a key that does not decode to 32 bytes" do
    assert {:error, error} = MediaCrypto.decrypt(<<0::128>>, Base.encode64("short"))
    assert error.message =~ "32 bytes"
  end

  test "rejects unaligned ciphertext and bad padding" do
    key = :crypto.strong_rand_bytes(32)
    aeskey = Base.encode64(key)

    assert {:error, unaligned} = MediaCrypto.decrypt(<<1, 2, 3>>, aeskey)
    assert unaligned.message =~ "block aligned"

    iv = binary_part(key, 0, 16)
    garbage = :crypto.crypto_one_time(:aes_256_cbc, key, iv, :binary.copy(<<0>>, 32), true)
    assert {:error, _bad_pad} = MediaCrypto.decrypt(garbage, aeskey)
  end
end
