defmodule Ankole.ActorRuntime.AIGatewayApiKeyBroker do
  @moduledoc """
  RuntimeFabric broker for agent-scoped AIGateway API keys.

  The key is scoped to the agent in the active turn. The worker receives no
  provider credentials through this RPC.
  """

  alias Ankole.ActorRuntime.WorkerRouteAuth
  alias Ankole.Principals
  alias AnkoleWeb.AIGatewayTokens
  alias AnkoleWeb.Endpoint

  @doc """
  Handles `ai_gateway.api_key_for.create_or_find_by_agent`.
  """
  @spec handle_request(map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_request(request, route) when is_map(request) and is_binary(route) do
    request_id = text(request, "request_id") || "ai-gateway-key-#{Ecto.UUID.generate()}"

    result =
      with {:ok, turn} <- turn_ref(request),
           {agent_uid, session_id} <- actor_identity(turn),
           :ok <- require_request_identity(request, agent_uid, session_id),
           :ok <- WorkerRouteAuth.authorize_turn_route(turn, route, :read),
           {:ok, %{principal: principal}} <- Principals.get_agent(agent_uid),
           :active <- principal.status,
           {:ok, token} <- AIGatewayTokens.mint_for_agent(principal.uid) do
        {:ok, response_payload(request_id, principal.uid, session_id, token)}
      end

    case result do
      {:ok, payload} ->
        {:ok, payload}

      {:error, reason} ->
        {agent_uid, session_id} =
          request
          |> turn_ref()
          |> case do
            {:ok, turn} ->
              actor_identity(turn)

            {:error, _reason} ->
              {text(request, "agent_uid") || "", text(request, "session_id") || ""}
          end

        {:error, error_payload(request_id, agent_uid, session_id, reason)}

      :disabled ->
        {:error,
         error_payload(
           request_id,
           text(request, "agent_uid") || "",
           text(request, "session_id") || "",
           :agent_disabled
         )}
    end
  end

  def handle_request(_request, _route),
    do: {:error, error_payload("", "", "", :invalid_ai_gateway_api_key_request)}

  defp require_request_identity(request, agent_uid, session_id) do
    case {text(request, "agent_uid"), text(request, "session_id")} do
      {nil, nil} -> :ok
      {^agent_uid, nil} -> :ok
      {nil, ^session_id} -> :ok
      {^agent_uid, ^session_id} -> :ok
      {_request_agent_uid, _request_session_id} -> {:error, :actor_identity_mismatch}
    end
  end

  defp response_payload(request_id, agent_uid, session_id, token) do
    %{
      "request_id" => request_id,
      "agent_uid" => agent_uid,
      "session_id" => session_id,
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

  defp error_payload(request_id, agent_uid, session_id, reason) do
    %{
      "request_id" => request_id,
      "code" => error_code(reason),
      "message" => error_message(reason),
      "details_json" => %{"agent_uid" => agent_uid, "session_id" => session_id}
    }
  end

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "ai_gateway_api_key_request_failed"

  defp error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_message({reason, details}), do: "#{inspect(reason)}: #{inspect(details)}"
  defp error_message(reason), do: inspect(reason)

  defp turn_ref(%{"turn" => turn}) when is_map(turn), do: {:ok, turn}
  defp turn_ref(%{turn: turn}) when is_map(turn), do: {:ok, stringify_keys(turn)}
  defp turn_ref(_request), do: {:error, :missing_turn_ref}

  defp actor_identity(%{"actor" => %{"agent_uid" => agent_uid, "session_id" => session_id}})
       when is_binary(agent_uid) and is_binary(session_id),
       do: {agent_uid, session_id}

  defp actor_identity(_turn), do: {"", ""}

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) and is_map(value) ->
        {Atom.to_string(key), stringify_keys(value)}

      {key, value} when is_atom(key) ->
        {Atom.to_string(key), value}

      {key, value} when is_map(value) ->
        {key, stringify_keys(value)}

      pair ->
        pair
    end)
  end

  defp text(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          text -> text
        end

      _value ->
        nil
    end
  end
end
