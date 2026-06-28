defmodule AnkoleWeb.AIGatewayTokens do
  @moduledoc """
  Agent-scoped JWT credentials for the AIGateway HTTP API.

  These tokens are not refresh-token backed. Workers keep them in memory and ask
  RuntimeFabric for a new token when the current one is absent or expired.
  """

  alias Ankole.Kernel, as: NativeKernel

  @issuer "ankole.control_plane"
  @audience "ankole.ai_gateway"
  @scope "ai_gateway"
  @token_use "api_key"
  @sub_key_id "ai_gateway.jwt.api_key"
  @ttl_seconds 30 * 24 * 60 * 60
  @clock_leeway_seconds 60

  @type token_set :: %{
          api_key: String.t(),
          token_type: String.t(),
          expires_in: pos_integer(),
          expires_at: integer(),
          scope: String.t(),
          agent_uid: String.t()
        }

  @doc """
  Mints one agent-scoped AIGateway API key.
  """
  @spec mint_for_agent(String.t()) :: {:ok, token_set()} | {:error, term()}
  def mint_for_agent(agent_uid) when is_binary(agent_uid) do
    now = now_seconds()
    expires_at = now + @ttl_seconds

    claims = %{
      aud: @audience,
      exp: expires_at,
      iat: now,
      iss: @issuer,
      jti: NativeKernel.gen_uuid_v7(),
      nbf: now,
      scope: @scope,
      sub: agent_uid,
      subject_type: "agent",
      token_use: @token_use
    }

    with {:ok, key} <- signing_key(),
         token when is_binary(token) <- NativeKernel.jwt_sign(claims, key, %{algorithm: "HS256"}) do
      {:ok,
       %{
         api_key: token,
         token_type: "Bearer",
         expires_in: @ttl_seconds,
         expires_at: expires_at,
         scope: @scope,
         agent_uid: agent_uid
       }}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:jwt_sign_failed, other}}
    end
  end

  def mint_for_agent(_agent_uid), do: {:error, :invalid_agent_uid}

  @doc """
  Verifies an AIGateway API key and returns JWT claims.
  """
  @spec verify_api_key(String.t()) :: {:ok, map()} | {:error, term()}
  def verify_api_key(token) when is_binary(token) do
    with {:ok, key} <- signing_key(),
         claims when is_map(claims) <- NativeKernel.jwt_verify(token, key, validation()),
         :ok <- require_claim(claims, "token_use", @token_use),
         :ok <- require_claim(claims, "scope", @scope),
         :ok <- require_claim(claims, "subject_type", "agent"),
         %{"sub" => sub} <- claims,
         true <- is_binary(sub) and sub != "" do
      {:ok, claims}
    else
      false -> {:error, :invalid_subject}
      %{} -> {:error, :invalid_subject}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:jwt_verify_failed, other}}
    end
  end

  def verify_api_key(_token), do: {:error, :invalid_token}

  defp signing_key do
    with {:ok, secret} <- root_secret(),
         key when is_binary(key) <- NativeKernel.derive_key(secret, @sub_key_id, nil) do
      {:ok, key}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:derive_key_failed, other}}
    end
  end

  defp validation do
    %{
      algorithms: ["HS256"],
      aud: [@audience],
      iss: [@issuer],
      leeway: @clock_leeway_seconds,
      required_spec_claims: ["exp", "nbf", "aud", "iss", "sub"],
      validate_exp: true,
      validate_nbf: true
    }
  end

  defp require_claim(claims, key, expected) do
    case Map.fetch(claims, key) do
      {:ok, ^expected} -> :ok
      {:ok, _value} -> {:error, {:invalid_claim, key}}
      :error -> {:error, {:missing_claim, key}}
    end
  end

  defp root_secret do
    :ankole
    |> Application.get_env(AnkoleWeb.Endpoint, [])
    |> Keyword.fetch(:secret_key_base)
    |> case do
      {:ok, secret} when is_binary(secret) and secret != "" -> {:ok, secret}
      {:ok, _secret} -> {:error, :invalid_secret_key_base}
      :error -> {:error, :missing_secret_key_base}
    end
  end

  defp now_seconds, do: System.system_time(:second)
end
