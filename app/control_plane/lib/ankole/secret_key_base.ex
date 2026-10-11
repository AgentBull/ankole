defmodule Ankole.SecretKeyBase do
  @moduledoc false

  @doc """
  Encrypts `plaintext` with a key derived from the root secret for `purpose`
  and `context`.

  The context names the row that owns the value. It is a JSON array, so its
  parts can hold any characters, and a ciphertext copied to another row or
  purpose does not decrypt.
  """
  @spec seal(binary(), String.t(), [term()]) :: {:ok, String.t()} | {:error, term()}
  def seal(plaintext, purpose, context) when is_binary(plaintext) do
    with {:ok, key} <- key(purpose, context),
         ciphertext when is_binary(ciphertext) <- Ankole.Kernel.aead_encrypt(plaintext, key),
         do: {:ok, ciphertext}
  end

  @doc "Decrypts a value that `seal/3` encrypted for the same purpose and context."
  @spec unseal(String.t(), String.t(), [term()]) :: {:ok, binary()} | {:error, term()}
  def unseal(ciphertext, purpose, context) when is_binary(ciphertext) do
    with {:ok, key} <- key(purpose, context),
         plaintext when is_binary(plaintext) <- Ankole.Kernel.aead_decrypt(ciphertext, key),
         do: {:ok, plaintext}
  end

  defp key(purpose, context) do
    with {:ok, secret} <- fetch(),
         do: {:ok, Ankole.Kernel.derive_key(secret, purpose, Ankole.JSON.encode!(context))}
  end

  @doc """
  Reads the Phoenix endpoint root secret from application config.
  """
  @spec fetch() ::
          {:ok, String.t()} | {:error, :invalid_secret_key_base | :missing_secret_key_base}
  def fetch do
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
