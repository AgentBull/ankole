defmodule Ankole.OIDC.Boruta.Codes do
  @moduledoc false

  @behaviour Boruta.Oauth.Codes

  import Ecto.Query, warn: false

  alias Ankole.OIDC.AuthorizationCode
  alias Ankole.OIDC.Boruta.Clients
  alias Ankole.OIDC.Boruta.ResourceOwners
  alias Ankole.OIDC.Boruta.TokenGenerator
  alias Ankole.Repo
  alias Boruta.Oauth.Token

  @impl true
  def get_by(value: value, redirect_uri: redirect_uri)
      when is_binary(value) and is_binary(redirect_uri) do
    digest = TokenGenerator.digest(value)

    case Repo.get_by(AuthorizationCode, digest: digest, redirect_uri: redirect_uri) do
      %AuthorizationCode{} = row -> from_row(row, value)
      nil -> nil
    end
  end

  def get_by(_params), do: nil

  @impl true
  def create(params) do
    with %{client: client, sub: sub, redirect_uri: redirect_uri, scope: scope} <- params,
         "S256" <- params[:code_challenge_method],
         challenge when is_binary(challenge) and challenge != "" <- params[:code_challenge],
         raw <- TokenGenerator.opaque_token(),
         now <- DateTime.utc_now(),
         expires_at <- DateTime.add(now, client.authorization_code_ttl, :second),
         changeset <-
           AuthorizationCode.changeset(%AuthorizationCode{}, %{
             digest: TokenGenerator.digest(raw),
             client_id: client.id,
             principal_uid: sub,
             redirect_uri: redirect_uri,
             scope: scope,
             state: params[:state],
             nonce: params[:nonce],
             code_challenge_digest: Token.hash(challenge),
             code_challenge_method: "S256",
             expires_at: expires_at
           }),
         {:ok, row} <- Repo.insert(changeset) do
      {:ok, from_row(row, raw)}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_pkce_request}
    end
  end

  @impl true
  def revoke(%Token{value: value} = token) when is_binary(value) do
    _ =
      Repo.delete_all(
        from code in AuthorizationCode, where: code.digest == ^TokenGenerator.digest(value)
      )

    {:ok, %{token | revoked_at: DateTime.utc_now()}}
  end

  def revoke(%Token{} = token), do: {:ok, %{token | revoked_at: DateTime.utc_now()}}

  @impl true
  def revoke_previous_token(%Token{} = token), do: revoke(token)

  defp from_row(row, raw) do
    with client when not is_nil(client) <- Clients.get_client(row.client_id),
         {:ok, resource_owner} <- ResourceOwners.load(row.principal_uid) do
      %Token{
        type: "code",
        value: raw,
        state: row.state,
        nonce: row.nonce,
        scope: row.scope,
        redirect_uri: row.redirect_uri,
        expires_at: DateTime.to_unix(row.expires_at),
        client: client,
        sub: row.principal_uid,
        resource_owner: resource_owner,
        inserted_at: row.inserted_at,
        code_challenge_hash: row.code_challenge_digest,
        code_challenge_method: row.code_challenge_method
      }
    else
      _invalid -> nil
    end
  end
end
