defmodule Ankole.SignalsGateway.ActorRuntime.AIGatewayAPIKeyBroker do
  @moduledoc """
  RuntimeFabric broker for agent-scoped AIGateway API keys.

  The key is scoped to the explicit agent uid in the RPC payload. The worker
  receives no provider credentials through this RPC.
  """

  alias Ankole.Principals
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire
  alias AnkoleWeb.AIGatewayTokens
  alias AnkoleWeb.Endpoint

  @doc """
  Handles `ai_gateway.api_key_for.create_or_find_by_agent`.
  """
  @spec handle_request(String.t() | nil, FabricProto.AIGatewayAPIKeyRequest.t(), map()) ::
          {:ok, FabricProto.AIGatewayAPIKeyResponse.t()} | {:error, map()}
  def handle_request(agent_uid, %FabricProto.AIGatewayAPIKeyRequest{}, ctx) do
    result =
      with {:ok, agent_uid} <- frame_agent_uid(agent_uid),
           {:ok, %{principal: principal}} <- Principals.get_agent(agent_uid),
           :active <- principal.status,
           {:ok, token} <- AIGatewayTokens.mint_for_agent(principal.uid) do
        {:ok, response(principal.uid, token)}
      end

    case result do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, error_payload(ctx.request_id, agent_uid, reason)}
      :disabled -> {:error, error_payload(ctx.request_id, agent_uid, :agent_disabled)}
    end
  end

  defp frame_agent_uid(nil), do: {:error, :missing_agent_uid}
  defp frame_agent_uid(agent_uid), do: Principals.normalize_uid(agent_uid)

  defp response(agent_uid, token) do
    %FabricProto.AIGatewayAPIKeyResponse{
      agent_uid: agent_uid,
      api_key: token.api_key,
      token_type: token.token_type,
      expires_at: token.expires_at,
      expires_in: token.expires_in,
      scope: token.scope,
      base_url: worker_facing_base_url()
    }
  end

  # The URL in this payload is consumed by the Agent Computer worker, not by a
  # browser or another control-plane process. In Docker e2e, `Endpoint.url/0`
  # points at localhost from the host VM, while the worker container must call
  # `host.docker.internal`. Keeping this as an explicit worker-facing setting
  # avoids leaking container networking details into the Phoenix endpoint config.
  defp worker_facing_base_url do
    configured =
      :ankole
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:worker_facing_base_url)

    case configured do
      nil ->
        Endpoint.url() <> "/api/v1/ai-gateway"

      value when is_binary(value) ->
        value = String.trim(value)

        if value == "" do
          Endpoint.url() <> "/api/v1/ai-gateway"
        else
          String.trim_trailing(value, "/")
        end

      value ->
        raise ArgumentError,
              "expected :worker_facing_base_url for #{inspect(__MODULE__)} to be a string, got: #{inspect(value)}"
    end
  end

  defp error_payload(request_id, agent_uid, reason) do
    RPCWire.error_payload(request_id, reason,
      fallback_code: "ai_gateway_api_key_request_failed",
      message_style: :inspect_tuple_reason,
      details_json: %{"agent_uid" => agent_uid || ""}
    )
  end
end
