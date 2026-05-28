defmodule BullX.Principals.Code do
  @moduledoc false

  require Logger

  @bootstrap_activation_code_length 8
  @login_auth_code_length 8
  @alphabet "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
  @alphabet_size byte_size(@alphabet)

  if rem(256, @alphabet_size) != 0 do
    raise "BullX.Principals.Code alphabet size must divide 256 for unbiased byte mapping"
  end

  @spec bootstrap_activation_code() :: String.t()
  def bootstrap_activation_code, do: random_code(@bootstrap_activation_code_length)

  @spec login_auth_code() :: String.t()
  def login_auth_code, do: random_code(@login_auth_code_length)

  @spec hash(String.t()) :: {:ok, String.t()} | {:error, term()}
  def hash(plaintext) when is_binary(plaintext) do
    case BullX.Ext.argon2_hash(plaintext) do
      hash when is_binary(hash) -> {:ok, hash}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec verify(String.t(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def verify(plaintext, hash) when is_binary(plaintext) and is_binary(hash) do
    case BullX.Ext.argon2_verify(plaintext, hash) do
      result when is_boolean(result) -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec verified?(String.t(), String.t()) :: boolean()
  def verified?(plaintext, hash) do
    case verify(plaintext, hash) do
      {:ok, result} ->
        result

      {:error, reason} ->
        Logger.debug("failed to verify BullX.Principals code hash: #{inspect(reason)}")
        false
    end
  end

  defp random_code(length) do
    length
    |> :crypto.strong_rand_bytes()
    |> :binary.bin_to_list()
    |> Enum.map(&binary_part(@alphabet, rem(&1, @alphabet_size), 1))
    |> IO.iodata_to_binary()
  end
end
