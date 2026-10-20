defmodule Ankole.OIDC.Boruta.IdTokens do
  @moduledoc false

  # Boruta 2.3.8 inserts the current time when last_login_at is absent. Preserve
  # its claims and hashes, but remove that unsupported assertion and our adapter data.
  def for_response(nil), do: {:ok, nil}

  def for_response(token) when is_binary(token) do
    %JOSE.JWT{fields: claims} = JOSE.JWT.peek_payload(token)
    authentication = claims["ankole_authentication"] || %{}
    claims = Map.delete(claims, "ankole_authentication")

    claims =
      if is_integer(authentication["auth_time"]),
        do: Map.put(claims, "auth_time", authentication["auth_time"]),
        else: Map.delete(claims, "auth_time")

    Ankole.TokenSigning.sign(claims, "JWT")
  end

  def client_id(token) do
    with {:ok, _header, claims} <- decode(token),
         id when is_binary(id) <- claims["aud"],
         do: {:ok, id},
         else: (_ -> {:error, :invalid_id_token_hint})
  end

  def verify_hint(token, client_id) do
    with {:ok, %{"alg" => "RS256", "typ" => "JWT", "kid" => kid}, _} <- decode(token),
         {:ok, key} <- Ankole.OIDC.SigningKey.get(),
         true <- kid == key.kid,
         claims when is_map(claims) <-
           Ankole.Kernel.jwt_verify_jwk(token, key.public_jwk, %{
             algorithms: ["RS256"],
             aud: [client_id],
             iss: [Ankole.TokenSigning.issuer()],
             required_spec_claims: ["exp", "iat", "aud", "iss", "sub"],
             validate_exp: false,
             validate_nbf: false
           }),
         true <-
           is_integer(claims["iat"]) and is_integer(claims["exp"]) and
             claims["iat"] <= System.system_time(:second) + 60,
         sid when is_binary(sid) <- claims["sid"] do
      {:ok, claims}
    else
      _ -> {:error, :invalid_id_token_hint}
    end
  end

  defp decode(token) when is_binary(token) do
    with [header, payload, _signature] <- String.split(token, "."),
         {:ok, header} <- Base.url_decode64(header, padding: false),
         {:ok, payload} <- Base.url_decode64(payload, padding: false),
         {:ok, %{} = header} <- Ankole.JSON.decode(header),
         {:ok, %{} = claims} <- Ankole.JSON.decode(payload) do
      {:ok, header, claims}
    else
      _ -> {:error, :invalid_id_token_hint}
    end
  end

  defp decode(_), do: {:error, :invalid_id_token_hint}
end
