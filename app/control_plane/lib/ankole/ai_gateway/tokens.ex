defmodule Ankole.AIGateway.Tokens do
  @moduledoc """
  Agent-scoped JWT credentials for the AIGateway HTTP API.

  These tokens are not refresh-token backed. Workers keep them in memory and ask
  RuntimeFabric for a new token when the current one is absent or expired.
  """

  alias Ankole.OIDC.Config
  alias Ankole.AgentWorkers.RunnerConnection

  @audience "ankole.ai_gateway"
  @scope "ai_gateway"
  @token_use "access"
  @ttl_seconds 30 * 24 * 60 * 60
  @runner_ttl_seconds 3600

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
  def mint_for_agent(agent_uid) when is_binary(agent_uid), do: mint(agent_uid, @ttl_seconds, %{})
  def mint_for_agent(_agent_uid), do: {:error, :invalid_agent_uid}

  def mint_for_worker(agent_uid, %{runner_id: runner_id} = worker) when is_binary(runner_id) do
    if RunnerConnection.current?(worker) do
      mint(agent_uid, @runner_ttl_seconds, %{
        "runner_worker" => %{
          "id" => runner_id,
          "generation" => worker.generation,
          "incarnation" => worker.incarnation_id
        }
      })
    else
      {:error, :stale_transport_route}
    end
  end

  def mint_for_worker(agent_uid, _worker), do: mint_for_agent(agent_uid)

  defp mint(agent_uid, ttl_seconds, extra_claims) do
    now = now_seconds()
    expires_at = now + ttl_seconds

    principal = %{
      kind: "agent",
      sub: agent_uid,
      scopes: [@scope],
      claims:
        Map.merge(
          %{"token_use" => @token_use, "tenant_id" => Ankole.Repo.tenant_id!()},
          extra_claims
        )
    }

    with {:ok, result} <-
           Attesto.Token.mint(Config.get(@audience, ttl_seconds), principal, now: now) do
      {:ok,
       %{
         api_key: result.access_token,
         token_type: "Bearer",
         expires_in: ttl_seconds,
         expires_at: expires_at,
         scope: @scope,
         agent_uid: agent_uid
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def authorize_worker_claims(%{
        "exp" => expires_at,
        "sub" => agent_uid,
        "runner_worker" => %{
          "id" => runner_id,
          "generation" => generation,
          "incarnation" => incarnation
        }
      })
      when is_integer(expires_at) and is_binary(agent_uid) and is_binary(runner_id) and
             is_binary(generation) and
             is_binary(incarnation) do
    if expires_at > now_seconds() and
         RunnerConnection.current?(%{
           worker_id: agent_uid,
           runner_id: runner_id,
           generation: generation,
           incarnation_id: incarnation
         }),
       do: :ok,
       else: {:error, :invalid_token}
  end

  def authorize_worker_claims(%{"runner_worker" => _}), do: {:error, :invalid_token}
  def authorize_worker_claims(_claims), do: :ok

  @doc """
  Validates Agent API key claims after `Attesto.Token` verifies the token.

  This function does not verify a token signature or registered JWT claims.
  """
  @spec validate_api_key_claims(map()) :: {:ok, map()} | {:error, term()}
  def validate_api_key_claims(%{} = claims) do
    with :ok <- require_claim(claims, "token_use", @token_use),
         :ok <- require_claim(claims, "scope", @scope),
         :ok <- require_claim(claims, "subject_type", "agent"),
         %{"sub" => sub, "tenant_id" => tenant_id} <- claims,
         {:ok, _} <- Ecto.UUID.cast(tenant_id),
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
