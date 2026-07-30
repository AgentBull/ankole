defmodule WeComOpenAPI.MediaCrypto do
  @moduledoc """
  Decrypts bot callback media downloads.

  Every image/file/video reference in a bot callback carries its own `aeskey`
  (Base64, unpadded) next to a temporary URL whose bytes are AES-256-CBC
  encrypted: IV is the first 16 bytes of the key and plaintext is PKCS#7 padded
  to a multiple of 32 bytes.
  """

  alias WeComOpenAPI.Error

  @max_pad 32

  @doc "Decrypt encrypted media bytes with the message-supplied `aeskey`."
  @spec decrypt(binary(), String.t()) :: {:ok, binary()} | {:error, Error.t()}
  def decrypt(ciphertext, aeskey) when is_binary(ciphertext) and is_binary(aeskey) do
    with {:ok, key} <- decode_key(aeskey),
         :ok <- validate_ciphertext(ciphertext) do
      iv = binary_part(key, 0, 16)
      plaintext = :crypto.crypto_one_time(:aes_256_cbc, key, iv, ciphertext, false)
      unpad(plaintext)
    end
  rescue
    error ->
      {:error, %Error{reason: :unexpected_shape, message: "media decrypt failed", raw: error}}
  end

  defp decode_key(aeskey) do
    padded = aeskey <> String.duplicate("=", rem(4 - rem(String.length(aeskey), 4), 4))

    case Base.decode64(padded) do
      {:ok, key} when byte_size(key) == 32 ->
        {:ok, key}

      _other ->
        {:error, %Error{reason: :unexpected_shape, message: "aeskey does not decode to 32 bytes"}}
    end
  end

  defp validate_ciphertext(ciphertext)
       when byte_size(ciphertext) > 0 and rem(byte_size(ciphertext), 16) == 0,
       do: :ok

  defp validate_ciphertext(_ciphertext) do
    {:error, %Error{reason: :unexpected_shape, message: "ciphertext is not block aligned"}}
  end

  defp unpad(plaintext) when byte_size(plaintext) > 0 do
    pad = :binary.last(plaintext)

    if pad >= 1 and pad <= @max_pad and pad <= byte_size(plaintext) and
         binary_part(plaintext, byte_size(plaintext) - pad, pad) ==
           :binary.copy(<<pad>>, pad) do
      {:ok, binary_part(plaintext, 0, byte_size(plaintext) - pad)}
    else
      {:error, %Error{reason: :unexpected_shape, message: "invalid PKCS#7 padding"}}
    end
  end

  defp unpad(_plaintext) do
    {:error, %Error{reason: :unexpected_shape, message: "empty plaintext"}}
  end
end
