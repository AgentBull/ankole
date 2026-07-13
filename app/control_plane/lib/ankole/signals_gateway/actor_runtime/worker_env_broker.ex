defmodule Ankole.SignalsGateway.ActorRuntime.WorkerEnvBroker do
  @moduledoc """
  RuntimeFabric RPC broker for worker shell environment reads.

  Agent Computer is a trusted first-party runtime node, so it receives the
  merged environment with secrets already decrypted. The flat map stays on
  the ephemeral RPC path; nothing durable stores it.
  """

  alias Ankole.Principals
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire
  alias Ankole.SignalsGateway.ActorRuntime.WorkerEnv

  @doc """
  Handles `worker_env.resolve`.
  """
  @spec handle_request(map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_request(request, _route) when is_map(request) do
    request_id =
      RPCWire.text(request, "request_id") || "worker-env-resolve-#{Ecto.UUID.generate()}"

    result =
      with {:ok, agent_uid} <- request_agent_uid(request),
           {:ok, %{principal: principal}} <- Principals.get_agent(agent_uid),
           :active <- principal.status,
           {:ok, vars} <- WorkerEnv.effective_env(principal.uid) do
        {:ok, response_payload(request_id, principal.uid, vars)}
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
    do: {:error, error_payload("", "", :invalid_worker_env_resolve_request)}

  defp request_agent_uid(request) do
    case RPCWire.text(request, "agent_uid") do
      nil -> {:error, :missing_agent_uid}
      agent_uid -> Principals.normalize_uid(agent_uid)
    end
  end

  defp response_payload(request_id, agent_uid, vars) do
    %{
      "request_id" => request_id,
      "agent_uid" => agent_uid,
      "vars" => vars
    }
  end

  defp error_payload(request_id, agent_uid, reason) do
    RPCWire.error_payload(request_id, reason,
      fallback_code: "worker_env_resolve_failed",
      message_style: :tuple_inspect,
      details_json: %{"agent_uid" => agent_uid}
    )
  end
end
