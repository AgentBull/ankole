defmodule Ankole.SignalsGateway.ActorRuntime.WorkerEnv.Crypto do
  @moduledoc """
  Kernel-backed encryption for secret worker shell variables.

  Values are plain strings by contract (shell variables), so no JSON
  round-trip happens here. The `worker_env` key-derivation domain keeps these
  ciphertexts unreadable as AppConfigure rows and vice versa.
  """

  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.SecretKeyBase

  @doc """
  Encrypts one shell variable value for a concrete row.

  The derived row key includes both scope and name, so a ciphertext copied to
  another row cannot decrypt as a valid value.
  """
  @spec seal(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def seal(value, scope, name) when is_binary(value) do
    with {:ok, row_key} <- row_key(scope, name),
         encrypted when is_binary(encrypted) <- NativeKernel.aead_encrypt(value, row_key) do
      {:ok, encrypted}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:encrypt_failed, other}}
    end
  end

  @doc """
  Decrypts one shell variable ciphertext back to its plaintext string.
  """
  @spec unseal(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def unseal(ciphertext, scope, name) when is_binary(ciphertext) do
    with {:ok, row_key} <- row_key(scope, name),
         plaintext when is_binary(plaintext) <- NativeKernel.aead_decrypt(ciphertext, row_key) do
      {:ok, plaintext}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:decrypt_failed, other}}
    end
  end

  # The context is a JSON array instead of a joined string, because scope and
  # name may contain separator characters. The serialized pair keeps key
  # derivation unambiguous without adding a custom escaping format.
  defp row_key(scope, name) do
    with {:ok, secret} <- SecretKeyBase.fetch() do
      context = Ankole.JSON.encode!([scope, name])
      {:ok, NativeKernel.derive_key(secret, "worker_env", context)}
    end
  end
end
