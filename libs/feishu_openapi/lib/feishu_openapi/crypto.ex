defmodule FeishuOpenAPI.Crypto do
  @moduledoc """
  Crypto primitives used by Feishu/Lark webhooks and card actions.

    * `decrypt/2` — AES-256-CBC with a SHA256-derived key; ciphertext layout is
      `IV(16) || encrypted_blocks`, PKCS#7 padded. Matches `larkevent.EventDecrypt`.
    * `encrypt/2` — the inverse of `decrypt/2`, used for tests and tooling.
    * `event_signature/4` — SHA256 of `timestamp || nonce || encrypt_key || body`,
      lower-case hex.
    * `card_signature/4` — SHA1 of `timestamp || nonce || token || body`,
      lower-case hex.
    * `verify_event/5` and `verify_card/5` — constant-time signature comparison.
  """

  @aes_block_size 16

  @doc """
  Decrypt a base64-encoded event/card payload using `secret` as the shared key.

  Returns `{:ok, plaintext_binary}` or `{:error, reason}`.
  """
  @spec decrypt(String.t(), String.t()) :: {:ok, binary()} | {:error, atom()}
  def decrypt(base64, secret) when is_binary(base64) and is_binary(secret) do
    with {:ok, buf} <- Base.decode64(base64, ignore: :whitespace),
         :ok <- check_len(buf),
         <<iv::binary-size(@aes_block_size), ciphertext::binary>> <- buf,
         :ok <- check_blocksize(ciphertext) do
      key = :crypto.hash(:sha256, secret)
      padded = :crypto.crypto_one_time(:aes_256_cbc, key, iv, ciphertext, false)
      pkcs7_unpad(padded)
    else
      :error -> {:error, :invalid_base64}
      {:error, _} = err -> err
      _ -> {:error, :malformed_ciphertext}
    end
  end

  @doc """
  Encrypt a plaintext binary. Returns base64 string matching `decrypt/2`'s input.
  """
  @spec encrypt(iodata(), String.t()) :: {:ok, String.t()}
  def encrypt(plaintext, secret) when is_binary(secret) do
    key = :crypto.hash(:sha256, secret)
    iv = :crypto.strong_rand_bytes(@aes_block_size)
    padded = pkcs7_pad(IO.iodata_to_binary(plaintext))
    ciphertext = :crypto.crypto_one_time(:aes_256_cbc, key, iv, padded, true)
    {:ok, Base.encode64(iv <> ciphertext)}
  end

  @doc """
  SHA256-based event signature (matches `larkevent.Signature`).

      iex> FeishuOpenAPI.Crypto.event_signature("1711111", "abc", "k", "{}")
      "..."
  """
  @spec event_signature(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def event_signature(timestamp, nonce, encrypt_key, body) do
    :sha256
    |> :crypto.hash(timestamp <> nonce <> encrypt_key <> body)
    |> Base.encode16(case: :lower)
  end

  @doc """
  SHA1-based card signature (matches `larkcard.Signature`).
  """
  @spec card_signature(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def card_signature(timestamp, nonce, verification_token, body) do
    :sha
    |> :crypto.hash(timestamp <> nonce <> verification_token <> body)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Constant-time verification of an event signature.

  Returns `:ok` or `{:error, :bad_signature}`.
  """
  @spec verify_event(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, :bad_signature}
  def verify_event(timestamp, nonce, encrypt_key, body, received) do
    if secure_equal?(event_signature(timestamp, nonce, encrypt_key, body), received),
      do: :ok,
      else: {:error, :bad_signature}
  end

  @doc "Constant-time verification of a card signature."
  @spec verify_card(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, :bad_signature}
  def verify_card(timestamp, nonce, verification_token, body, received) do
    if secure_equal?(card_signature(timestamp, nonce, verification_token, body), received),
      do: :ok,
      else: {:error, :bad_signature}
  end

  # --- internals -----------------------------------------------------------

  defp check_len(buf) when byte_size(buf) < @aes_block_size, do: {:error, :cipher_too_short}
  defp check_len(_), do: :ok

  defp check_blocksize(ct) when rem(byte_size(ct), @aes_block_size) != 0,
    do: {:error, :not_block_aligned}

  defp check_blocksize(_), do: :ok

  defp pkcs7_pad(bin) do
    pad = @aes_block_size - rem(byte_size(bin), @aes_block_size)
    bin <> :binary.copy(<<pad>>, pad)
  end

  defp pkcs7_unpad(bin) when is_binary(bin) and byte_size(bin) > 0 do
    pad = :binary.last(bin)

    cond do
      pad in 1..@aes_block_size and byte_size(bin) >= pad ->
        stripped_size = byte_size(bin) - pad
        <<stripped::binary-size(^stripped_size), padding::binary-size(^pad)>> = bin

        if padding == :binary.copy(<<pad>>, pad) do
          {:ok, stripped}
        else
          {:error, :invalid_padding}
        end

      true ->
        {:error, :invalid_padding}
    end
  end

  defp pkcs7_unpad(_bin), do: {:error, :invalid_padding}

  defp secure_equal?(a, b) when is_binary(a) and is_binary(b) do
    # Constant-time comparison; length mismatch is still reported as unequal
    # but leaks the length, which is acceptable for hex-encoded signatures.
    if byte_size(a) == byte_size(b) do
      :crypto.hash_equals(a, b)
    else
      false
    end
  rescue
    UndefinedFunctionError ->
      # Pre-OTP 25 fallback
      byte_size(a) == byte_size(b) and constant_time_binary_eq(a, b)
  end

  defp constant_time_binary_eq(<<>>, <<>>), do: true

  defp constant_time_binary_eq(<<a, ar::binary>>, <<b, br::binary>>) do
    acc = Bitwise.bxor(a, b)
    rest = constant_time_binary_eq(ar, br)
    acc == 0 and rest
  end

  defp constant_time_binary_eq(_, _), do: false
end
