defmodule Ankole.OIDC.Boruta.TokenGenerator do
  @moduledoc false

  @behaviour Boruta.Oauth.TokenGenerator

  @impl true
  def generate(_type, _token), do: opaque_token()

  @impl true
  def secret(_client), do: opaque_token()

  def opaque_token do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  def digest(value) when is_binary(value) do
    :crypto.hash(:sha256, value) |> Base.url_encode64(padding: false)
  end
end
