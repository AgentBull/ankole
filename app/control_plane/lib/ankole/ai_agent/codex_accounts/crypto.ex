defmodule Ankole.AIAgent.CodexAccounts.Crypto do
  @moduledoc false

  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.SecretKeyBase

  @purpose "codex_account_auth"

  @spec seal(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def seal(auth_json, account_id) when is_binary(auth_json) and is_binary(account_id) do
    with {:ok, key} <- account_key(account_id),
         ciphertext when is_binary(ciphertext) <- NativeKernel.aead_encrypt(auth_json, key) do
      {:ok, ciphertext}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:encrypt_failed, other}}
    end
  end

  def seal(_auth_json, _account_id), do: {:error, :invalid_codex_auth}

  @spec unseal(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def unseal(ciphertext, account_id) when is_binary(ciphertext) and is_binary(account_id) do
    with {:ok, key} <- account_key(account_id),
         auth_json when is_binary(auth_json) <- NativeKernel.aead_decrypt(ciphertext, key) do
      {:ok, auth_json}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:decrypt_failed, other}}
    end
  end

  def unseal(_ciphertext, _account_id), do: {:error, :invalid_codex_auth}

  defp account_key(account_id) do
    with {:ok, secret} <- SecretKeyBase.fetch() do
      {:ok, NativeKernel.derive_key(secret, @purpose, "codex_accounts:#{account_id}")}
    end
  end
end
