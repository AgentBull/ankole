defmodule Ankole.SignalsGateway.ActorRuntime.WorkerEnvBroker do
  @moduledoc """
  RuntimeFabric RPC broker for worker shell environment reads.

  Agent Computer is a trusted first-party runtime node, so it receives the
  merged environment with secrets already decrypted. The flat map stays on
  the ephemeral RPC path; nothing durable stores it.
  """

  alias Ankole.Principals
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire
  alias Ankole.SignalsGateway.ActorRuntime.WorkerEnv

  @doc """
  Handles `worker_env.resolve`.
  """
  @spec handle_request(String.t() | nil, FabricProto.WorkerEnvResolveRequest.t(), map()) ::
          {:ok, FabricProto.WorkerEnvResolveResponse.t()} | {:error, map()}
  def handle_request(agent_uid, %FabricProto.WorkerEnvResolveRequest{} = request, ctx) do
    result =
      with {:ok, agent_uid} <- frame_agent_uid(agent_uid),
           {:ok, %{principal: principal}} <- Principals.get_agent(agent_uid),
           :active <- principal.status,
           {:ok, %{operator: operator, binding: binding}} <-
             WorkerEnv.effective_env_parts(principal.uid,
               binding_name: optional_text(request.binding_name)
             ) do
        {:ok,
         %FabricProto.WorkerEnvResolveResponse{
           vars: Map.merge(operator, binding),
           operator_vars: operator,
           binding_vars: binding
         }}
      end

    case result do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, error_payload(ctx.request_id, agent_uid, reason)}
      :disabled -> {:error, error_payload(ctx.request_id, agent_uid, :agent_disabled)}
    end
  end

  defp frame_agent_uid(nil), do: {:error, :missing_agent_uid}
  defp frame_agent_uid(agent_uid), do: Principals.normalize_uid(agent_uid)

  defp optional_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp optional_text(_value), do: nil

  defp error_payload(request_id, agent_uid, reason) do
    RPCWire.error_payload(request_id, reason,
      fallback_code: "worker_env_resolve_failed",
      message_style: :tuple_inspect,
      details_json: %{"agent_uid" => agent_uid || ""}
    )
  end
end
