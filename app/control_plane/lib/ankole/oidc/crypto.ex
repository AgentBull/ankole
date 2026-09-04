defmodule Ankole.OIDC.Crypto do
  @moduledoc false

  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.SecretKeyBase

  @spec seal(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def seal(plaintext, kind, id)
      when is_binary(plaintext) and is_binary(kind) and is_binary(id) do
    with {:ok, key} <- row_key(kind, id),
         ciphertext when is_binary(ciphertext) <- NativeKernel.aead_encrypt(plaintext, key) do
      {:ok, ciphertext}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:encrypt_failed, other}}
    end
  end

  @spec unseal(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def unseal(ciphertext, kind, id)
      when is_binary(ciphertext) and is_binary(kind) and is_binary(id) do
    with {:ok, key} <- row_key(kind, id),
         plaintext when is_binary(plaintext) <- NativeKernel.aead_decrypt(ciphertext, key) do
      {:ok, plaintext}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:decrypt_failed, other}}
    end
  end

  defp row_key(kind, id) do
    with {:ok, root} <- SecretKeyBase.fetch() do
      context = Ankole.JSON.encode!([kind, id])
      {:ok, NativeKernel.derive_key(root, "oidc", context)}
    end
  end
end
