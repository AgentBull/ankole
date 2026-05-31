defmodule BullX.LLM.Crypto do
  @moduledoc """
  Encrypts LLM provider API keys with per-row derived keys.

  The root secret never becomes the stored encryption key. Each provider row id
  derives a subkey so copied ciphertext cannot be moved between rows and still
  decrypt successfully.
  """

  @sub_key_prefix "llm_providers/"

  @spec encrypt_api_key(String.t() | nil, Ecto.UUID.t()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def encrypt_api_key(nil, _row_id), do: {:ok, nil}
  def encrypt_api_key("", _row_id), do: {:ok, nil}

  def encrypt_api_key(plaintext, row_id) when is_binary(plaintext) and is_binary(row_id) do
    with {:ok, key} <- derive_key(row_id) do
      case BullX.Ext.aead_encrypt(plaintext, key) do
        ciphertext when is_binary(ciphertext) -> {:ok, ciphertext}
        {:error, _reason} = error -> error
      end
    end
  end

  @spec decrypt_api_key(String.t() | nil, Ecto.UUID.t()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def decrypt_api_key(nil, _row_id), do: {:ok, nil}

  def decrypt_api_key(ciphertext, row_id) when is_binary(ciphertext) and is_binary(row_id) do
    with {:ok, key} <- derive_key(row_id) do
      case BullX.Ext.aead_decrypt(ciphertext, key) do
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
        {:error, _reason} = error -> error
      end
    end
  end

  defp derive_key(row_id) do
    case BullX.Ext.derive_key(
           BullX.Config.Secrets.secret_base!(),
           @sub_key_prefix <> row_id,
           "api_key"
         ) do
      key when is_binary(key) -> {:ok, key}
      {:error, _reason} = error -> error
    end
  end
end
