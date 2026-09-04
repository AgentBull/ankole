defmodule Ankole.OIDC.Boruta.Clients do
  @moduledoc false

  @behaviour Boruta.Oauth.Clients

  alias Ankole.OIDC
  alias Ankole.OIDC.Client
  alias Ankole.OIDC.SigningKey
  alias Boruta.Oauth.Client, as: BorutaClient
  alias Boruta.Oauth.Scope

  @impl true
  def get_client(id) do
    with {:ok, %Client{} = client} <- OIDC.get_active_client(id),
         {:ok, secret} <- OIDC.client_secret(client),
         {:ok, signing_key} <- SigningKey.get() do
      %BorutaClient{
        id: client.id,
        name: client.name,
        secret: secret,
        confidential: client.client_type == :confidential,
        authorize_scope: true,
        authorized_scopes: scopes(client.scopes),
        redirect_uris: client.redirect_uris,
        supported_grant_types: ["authorization_code", "refresh_token"],
        access_token_ttl: 30 * 60,
        id_token_ttl: 5 * 60,
        authorization_code_ttl: 5 * 60,
        refresh_token_ttl: 30 * 24 * 60 * 60,
        pkce: true,
        public_refresh_token: client.client_type == :public,
        public_revoke: false,
        id_token_signature_alg: "RS256",
        id_token_kid: signing_key.kid,
        token_endpoint_auth_methods:
          if(client.client_type == :confidential, do: ["client_secret_basic"], else: []),
        private_key: signing_key.private_key_pem,
        metadata: %{"enabled" => client.enabled}
      }
    else
      _error -> nil
    end
  end

  @impl true
  def authorized_scopes(%BorutaClient{authorized_scopes: scopes}), do: scopes

  @impl true
  def list_clients_jwk do
    with {:ok, jwk} <- SigningKey.public_jwk(), do: [JOSE.JWK.from_map(jwk)], else: (_ -> [])
  end

  defp scopes(names), do: Enum.map(names, &%Scope{name: &1, label: &1, public: false})
end
