defmodule Ankole.OIDCClientFixture do
  @moduledoc false

  def token(issuer, client_id, claims \\ %{}) do
    key = JOSE.JWK.generate_key({:rsa, 2048})
    now = System.system_time(:second)

    claims =
      Map.merge(
        %{
          "iss" => issuer,
          "aud" => client_id,
          "sub" => "subject-1",
          "iat" => now,
          "exp" => now + 300,
          "nonce" => "nonce-1"
        },
        claims
      )

    {_header, token} =
      key
      |> JOSE.JWT.sign(%{"alg" => "RS256", "kid" => "login-test"}, claims)
      |> JOSE.JWS.compact()

    {_key, public} = JOSE.JWK.to_public_map(key)
    {token, %{"keys" => [Map.merge(public, %{"kid" => "login-test", "alg" => "RS256"})]}}
  end

  def discovery(conn, issuer, jwks) do
    uri = URI.parse(issuer)
    true = conn.host == uri.host
    keys_path = (URI.parse(issuer).path || "") <> "/keys"
    metadata_path = (uri.path || "") <> "/.well-known/openid-configuration"

    case conn.request_path do
      ^keys_path ->
        Req.Test.json(conn, jwks)

      ^metadata_path ->
        Req.Test.json(conn, %{"issuer" => issuer, "jwks_uri" => issuer <> "/keys"})
    end
  end
end
