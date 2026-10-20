defmodule Ankole.AIGateway.ProviderConfigs.Crypto do
  @moduledoc """
  Encrypts AIGateway provider options as JSON, bound to the provider row id and
  option key.
  """

  alias Ankole.SecretKeyBase

  @spec seal(term(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def seal(value, provider_row_id, option_key) do
    with {:ok, json} <- Ankole.JSON.encode(value),
         do:
           SecretKeyBase.seal(
             json,
             "ai_gateway_provider_option",
             context(provider_row_id, option_key)
           )
  end

  @spec unseal(String.t(), String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def unseal(ciphertext, provider_row_id, option_key) do
    with {:ok, json} <-
           SecretKeyBase.unseal(
             ciphertext,
             "ai_gateway_provider_option",
             context(provider_row_id, option_key)
           ),
         do: Ankole.JSON.decode(json)
  end

  defp context(provider_row_id, option_key),
    do: ["ai_gateway_providers", provider_row_id, option_key]
end
