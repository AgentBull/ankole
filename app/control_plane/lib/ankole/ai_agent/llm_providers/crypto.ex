defmodule Ankole.AIAgent.LlmProviders.Crypto do
  @moduledoc """
  AEAD wrapper for LLM provider credentials.

  Ciphertexts are bound to the provider row id so copying one provider's
  ciphertext to another row cannot decrypt as a valid credential.
  """

  alias Ankole.Kernel, as: NativeKernel

  @purpose "llm_provider_credential"

  @spec seal(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def seal(credential, provider_id) when is_binary(credential) and is_binary(provider_id) do
    with {:ok, row_key} <- row_key(provider_id),
         encrypted when is_binary(encrypted) <- NativeKernel.aead_encrypt(credential, row_key) do
      {:ok, encrypted}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:encrypt_failed, other}}
    end
  end

  def seal(_credential, _provider_id), do: {:error, :invalid_credential}

  @spec unseal(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def unseal(ciphertext, provider_id) when is_binary(ciphertext) and is_binary(provider_id) do
    with {:ok, row_key} <- row_key(provider_id),
         plaintext when is_binary(plaintext) <- NativeKernel.aead_decrypt(ciphertext, row_key) do
      {:ok, plaintext}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:decrypt_failed, other}}
    end
  end

  def unseal(_ciphertext, _provider_id), do: {:error, :invalid_credential}

  defp row_key(provider_id) do
    with {:ok, secret} <- root_secret() do
      context = "llm_providers:#{provider_id}:credential"
      {:ok, NativeKernel.derive_key(secret, @purpose, context)}
    end
  end

  # Roots the per-row key derivation in the endpoint's `secret_key_base` rather
  # than a separate KMS: one operator-managed secret already gates the
  # installation, so provider credentials are bound to it. Rotating it
  # invalidates all stored ciphertexts.
  defp root_secret do
    :ankole
    |> Application.get_env(AnkoleWeb.Endpoint, [])
    |> Keyword.fetch(:secret_key_base)
    |> case do
      {:ok, secret} when is_binary(secret) and secret != "" -> {:ok, secret}
      {:ok, _secret} -> {:error, :invalid_secret_key_base}
      :error -> {:error, :missing_secret_key_base}
    end
  end
end
