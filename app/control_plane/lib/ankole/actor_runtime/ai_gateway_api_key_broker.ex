defmodule Ankole.ActorRuntime.AIGatewayApiKeyBroker do
  @moduledoc """
  RuntimeFabric broker for agent-scoped AIGateway API keys.

  The key is scoped to the explicit agent uid in the RPC payload. The worker
  receives no provider credentials through this RPC.
  """

  alias Ankole.ActorRuntime.RPCWire
  alias Ankole.Principals
  alias AnkoleWeb.AIGatewayTokens
  alias AnkoleWeb.Endpoint

  @doc """
  Handles `ai_gateway.api_key_for.create_or_find_by_agent`.
  """
  @spec handle_request(map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_request(request, _route) when is_map(request) do
    request_id = RPCWire.text(request, "request_id") || "ai-gateway-key-#{Ecto.UUID.generate()}"

    result =
      with {:ok, agent_uid} <- request_agent_uid(request),
           {:ok, %{principal: principal}} <- Principals.get_agent(agent_uid),
           :active <- principal.status,
           {:ok, token} <- AIGatewayTokens.mint_for_agent(principal.uid) do
        {:ok, response_payload(request_id, principal.uid, token)}
      end

    case result do
      {:ok, payload} ->
        {:ok, payload}

      {:error, reason} ->
        {:error, error_payload(request_id, RPCWire.text(request, "agent_uid") || "", reason)}

      :disabled ->
        {:error,
         error_payload(request_id, RPCWire.text(request, "agent_uid") || "", :agent_disabled)}
    end
  end

  def handle_request(_request, _route),
    do: {:error, error_payload("", "", :invalid_ai_gateway_api_key_request)}

  defp request_agent_uid(request) do
    case RPCWire.text(request, "agent_uid") do
      nil -> {:error, :missing_agent_uid}
      agent_uid -> Principals.normalize_uid(agent_uid)
    end
  end

  defp response_payload(request_id, agent_uid, token) do
    %{
      "request_id" => request_id,
      "agent_uid" => agent_uid,
      "api_key" => token.api_key,
      "token_type" => token.token_type,
      "expires_at" => token.expires_at,
      "expires_in" => token.expires_in,
      "scope" => token.scope,
      "base_url" => worker_facing_base_url()
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
      details_json: %{"agent_uid" => agent_uid}
    )
  end
end
