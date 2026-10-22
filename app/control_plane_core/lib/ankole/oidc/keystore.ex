defmodule Ankole.OIDC.Keystore do
  @moduledoc false
  @behaviour Attesto.Keystore
  @impl true
  def verification_pems, do: [signing_pem()]
  @impl true
  def signing_pem do
    {:ok, key} = Ankole.OIDC.SigningKey.get()
    key.private_key_pem
  end

  @impl true
  def signing_alg, do: "RS256"
end
