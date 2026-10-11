defmodule Ankole.AppConfigure.Crypto do
  @moduledoc """
  Encrypts AppConfigure secret rows as JSON, bound to their scope and key.
  """

  alias Ankole.SecretKeyBase

  @spec seal(term(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def seal(value, scope, key) do
    with {:ok, json} <- Ankole.JSON.encode(value),
         do: SecretKeyBase.seal(json, "app_configure", [scope, key])
  end

  @doc "The caller still validates the decoded value against the registered schema."
  @spec unseal(String.t(), String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def unseal(ciphertext, scope, key) do
    with {:ok, json} <- SecretKeyBase.unseal(ciphertext, "app_configure", [scope, key]),
         do: Ankole.JSON.decode(json)
  end
end
