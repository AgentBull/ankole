defmodule Ankole.AIGateway.ProviderConfigs.Crypto do
  @moduledoc """
  AEAD wrapper for encrypted AIGateway provider options.

  Ciphertexts are bound to the provider row id and option key, so copying one
  provider option ciphertext to another row or key cannot decrypt as a valid
  value.
  """

  alias Ankole.Kernel, as: NativeKernel

  @purpose "ai_gateway_provider_option"

  @doc """
  Encrypts one JSON-compatible provider option for a provider row.
  """
  @spec seal(term(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def seal(value, provider_row_id, option_key)
      when is_binary(provider_row_id) and is_binary(option_key) do
    with {:ok, json} <- Ankole.JSON.encode(value),
         {:ok, row_key} <- row_key(provider_row_id, option_key),
         encrypted when is_binary(encrypted) <- NativeKernel.aead_encrypt(json, row_key) do
      {:ok, encrypted}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:encrypt_failed, other}}
    end
  end

  def seal(_value, _provider_row_id, _option_key), do: {:error, :invalid_encrypted_option}

  @doc """
  Decrypts one provider option that was sealed for the same row and key.
  """
  @spec unseal(String.t(), String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def unseal(ciphertext, provider_row_id, option_key)
      when is_binary(ciphertext) and is_binary(provider_row_id) and is_binary(option_key) do
    with {:ok, row_key} <- row_key(provider_row_id, option_key),
         plaintext when is_binary(plaintext) <- NativeKernel.aead_decrypt(ciphertext, row_key),
         {:ok, value} <- Ankole.JSON.decode(plaintext) do
      {:ok, value}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:decrypt_failed, other}}
    end
  end

  def unseal(_ciphertext, _provider_row_id, _option_key), do: {:error, :invalid_encrypted_option}

  # Deriving a row-and-key-specific AEAD key makes ciphertexts non-portable
  # across provider rows and option names. That is the useful guarantee here;
  # provider-specific validation still belongs to provider code.
  defp row_key(provider_row_id, option_key) do
    with {:ok, secret} <- root_secret() do
      context = Ankole.JSON.encode!(["ai_gateway_providers", provider_row_id, option_key])
      {:ok, NativeKernel.derive_key(secret, @purpose, context)}
    end
  end

  # Roots the per-row key derivation in the endpoint's `secret_key_base` rather
  # than a separate KMS: one operator-managed secret already gates the
  # installation, so encrypted provider options are bound to it. Rotating it
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
