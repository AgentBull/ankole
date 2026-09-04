defmodule Ankole.AIGateway.Tokens do
  @moduledoc """
  Agent-scoped JWT credentials for the AIGateway HTTP API.

  These tokens are not refresh-token backed. Workers keep them in memory and ask
  RuntimeFabric for a new token when the current one is absent or expired.
  """

  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.TokenSigning

  @audience "ankole.ai_gateway"
  @scope "ai_gateway"
  @token_use "access"
  @ttl_seconds 30 * 24 * 60 * 60

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
      iss: TokenSigning.issuer(),
      jti: NativeKernel.gen_uuid_v7(),
      nbf: now,
      scope: @scope,
      sub: agent_uid,
      subject_type: "agent",
      token_use: @token_use
    }

    with {:ok, token} <- TokenSigning.sign(claims, "at+jwt") do
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
    end
  end

  def mint_for_agent(_agent_uid), do: {:error, :invalid_agent_uid}

  @doc """
  Verifies an AIGateway API key and returns JWT claims.
  """
  @spec verify_api_key(String.t()) :: {:ok, map()} | {:error, term()}
  def verify_api_key(token) when is_binary(token) do
    with {:ok, claims} <- TokenSigning.verify(token, @audience, "at+jwt") do
      validate_api_key_claims(claims)
    end
  end

  def verify_api_key(_token), do: {:error, :invalid_token}

  @doc """
  Validates Agent API key claims after `TokenSigning` verifies the token.

  This function does not verify a token signature or registered JWT claims.
  """
  @spec validate_api_key_claims(map()) :: {:ok, map()} | {:error, term()}
  def validate_api_key_claims(%{} = claims) do
    with :ok <- require_claim(claims, "token_use", @token_use),
         :ok <- require_claim(claims, "scope", @scope),
         :ok <- require_claim(claims, "subject_type", "agent"),
         %{"sub" => sub} <- claims,
         true <- is_binary(sub) and sub != "" do
      {:ok, claims}
    else
      false -> {:error, :invalid_subject}
      %{} -> {:error, :invalid_subject}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_api_key_claims(_claims), do: {:error, :invalid_token}

  defp require_claim(claims, key, expected) do
    case Map.fetch(claims, key) do
      {:ok, ^expected} -> :ok
      {:ok, _value} -> {:error, {:invalid_claim, key}}
      :error -> {:error, {:missing_claim, key}}
    end
  end

  defp now_seconds, do: System.system_time(:second)
end
