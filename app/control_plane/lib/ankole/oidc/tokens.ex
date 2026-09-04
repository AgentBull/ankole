defmodule Ankole.OIDC.Tokens do
  @moduledoc false

  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.TokenSigning

  @access_ttl_seconds 30 * 60
  @userinfo_audience "ankole.oidc_userinfo"
  @ai_gateway_audience "ankole.ai_gateway"
  @access_token_use "access"

  def access_ttl_seconds, do: @access_ttl_seconds
  def userinfo_audience, do: @userinfo_audience
  def ai_gateway_audience, do: @ai_gateway_audience

  @spec mint_access(String.t(), String.t(), String.t()) ::
          {:ok, %{token: String.t(), expires_at: integer(), inserted_at: DateTime.t()}}
          | {:error, term()}
  def mint_access(principal_uid, client_id, scope) do
    now = System.system_time(:second)
    expires_at = now + @access_ttl_seconds

    claims = %{
      aud: audiences(scope),
      client_id: client_id,
      exp: expires_at,
      iat: now,
      iss: TokenSigning.issuer(),
      jti: NativeKernel.gen_uuid_v7(),
      nbf: now,
      scope: scope,
      sub: principal_uid,
      subject_type: "human",
      token_use: @access_token_use
    }

    with {:ok, token} <- TokenSigning.sign(claims, "at+jwt") do
      {:ok, %{token: token, expires_at: expires_at, inserted_at: DateTime.from_unix!(now)}}
    end
  end

  @spec verify_access(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def verify_access(token, audience) when is_binary(token) and is_binary(audience) do
    with {:ok, claims} <- TokenSigning.verify(token, audience, "at+jwt") do
      validate_access_claims(claims)
    end
  end

  def verify_access(_token, _audience), do: {:error, :invalid_token}

  @doc """
  Validates OIDC access-token claims after `TokenSigning` verifies the token.

  This function does not verify a token signature or registered JWT claims.
  """
  @spec validate_access_claims(map()) :: {:ok, map()} | {:error, term()}
  def validate_access_claims(%{} = claims) do
    with :ok <- require_claim(claims, "token_use", @access_token_use),
         :ok <- require_claim(claims, "subject_type", "human"),
         :ok <- require_scope(claims, "openid"),
         %{"client_id" => client_id, "sub" => sub} <- claims,
         true <- is_binary(client_id) and client_id != "" and is_binary(sub) and sub != "" do
      {:ok, claims}
    else
      false -> {:error, :invalid_subject}
      %{} -> {:error, :invalid_subject}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_access_claims(_claims), do: {:error, :invalid_token}

  defp audiences(scope) do
    if "ai_gateway.write" in String.split(scope, " ", trim: true),
      do: [@userinfo_audience, @ai_gateway_audience],
      else: [@userinfo_audience]
  end

  defp require_scope(%{"scope" => scope}, required) when is_binary(scope) do
    if required in String.split(scope, " ", trim: true),
      do: :ok,
      else: {:error, {:missing_scope, required}}
  end

  defp require_scope(_claims, required), do: {:error, {:missing_scope, required}}

  defp require_claim(claims, key, expected) do
    if Map.get(claims, key) == expected,
      do: :ok,
      else: {:error, {:invalid_claim, key}}
  end
end
