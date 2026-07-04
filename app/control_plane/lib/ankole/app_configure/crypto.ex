defmodule Ankole.AppConfigure.Crypto do
  @moduledoc """
  Kernel-backed encryption for AppConfigure secret rows.
  """

  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.SecretKeyBase

  @doc """
  Encrypts one JSON-compatible value for a concrete AppConfigure row.

  The derived row key includes both scope and key, so a ciphertext copied to
  another row cannot decrypt as a valid value.
  """
  @spec seal(term(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def seal(value, scope, key) do
    with {:ok, json} <- Ankole.JSON.encode(value),
         {:ok, row_key} <- row_key(scope, key),
         encrypted when is_binary(encrypted) <- NativeKernel.aead_encrypt(json, row_key) do
      {:ok, encrypted}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:encrypt_failed, other}}
    end
  end

  @doc """
  Decrypts one AppConfigure ciphertext and decodes the sealed JSON value.

  The caller still validates the decoded value against the registered schema;
  this module only owns encryption and JSON round-tripping.
  """
  @spec unseal(String.t(), String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def unseal(ciphertext, scope, key) do
    with {:ok, row_key} <- row_key(scope, key),
         plaintext when is_binary(plaintext) <- NativeKernel.aead_decrypt(ciphertext, row_key),
         {:ok, value} <- Ankole.JSON.decode(plaintext) do
      {:ok, value}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:decrypt_failed, other}}
    end
  end

  # The context is a JSON array instead of a joined string, because scope and key
  # may contain separator characters. The serialized pair keeps key derivation
  # unambiguous without adding a custom escaping format.
  defp row_key(scope, key) do
    with {:ok, secret} <- SecretKeyBase.fetch() do
      context = Ankole.JSON.encode!([scope, key])
      {:ok, NativeKernel.derive_key(secret, "app_configure", context)}
    end
  end
end
