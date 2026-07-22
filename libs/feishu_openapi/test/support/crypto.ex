defmodule FeishuOpenAPI.CryptoTestSupport do
  @moduledoc false

  @aes_block_size 16

  def encrypt(plaintext, secret) when is_binary(secret) do
    key = :crypto.hash(:sha256, secret)
    iv = :crypto.strong_rand_bytes(@aes_block_size)
    padded = pkcs7_pad(IO.iodata_to_binary(plaintext))
    ciphertext = :crypto.crypto_one_time(:aes_256_cbc, key, iv, padded, true)
    {:ok, Base.encode64(iv <> ciphertext)}
  end

  defp pkcs7_pad(binary) do
    pad = @aes_block_size - rem(byte_size(binary), @aes_block_size)
    binary <> :binary.copy(<<pad>>, pad)
  end
end
