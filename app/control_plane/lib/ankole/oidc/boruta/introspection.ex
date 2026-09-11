defmodule Ankole.OIDC.Boruta.Introspection do
  @moduledoc false
  alias Boruta.Oauth.{Authorization, IntrospectResponse, Token}

  # Boruta's Introspect checks only access tokens. Reuse its Client authentication
  # and both credential validators, then limit the result to the calling Client.
  def check(request) do
    with {:ok, _key} <- Ankole.OIDC.SigningKey.get(),
         {:ok, _providers} <- Ankole.IdentityProviders.Login.list_login_providers(),
         {:ok, client} <-
           Authorization.Client.authorize(
             id: request.client_id,
             source: request.client_authentication,
             grant_type: "introspect"
           ) do
      case credential(request.token) do
        {:ok, %Token{client: %{id: id}} = token} when id == client.id ->
          response = IntrospectResponse.from_token(token)
          {:ok, Map.take(response, [:active, :iss, :sub, :client_id, :scope, :exp, :iat])}

        _ ->
          {:ok, %{active: false}}
      end
    else
      {:error, %Boruta.Oauth.Error{}} = error -> error
      {:error, _} -> {:error, :temporarily_unavailable}
    end
  end

  defp credential(token) do
    case Authorization.AccessToken.authorize(value: token) do
      {:ok, _} = active -> active
      {:error, _} -> Authorization.AccessToken.authorize(refresh_token: token)
    end
  end
end
