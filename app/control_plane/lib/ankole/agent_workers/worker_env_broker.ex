defmodule Ankole.AgentWorkers.WorkerEnvBroker do
  @moduledoc """
  RuntimeFabric RPC broker for worker shell environment reads.

  Operator shell variables travel on the ephemeral RPC path. Credentials named
  by remote MCP Skill declarations stay in the control plane; the Worker uses
  its short-lived internal gateway context.
  """

  alias Ankole.Principals
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.AgentWorkers.RPCWire
  alias Ankole.AgentWorkers.WorkerEnv

  @doc """
  Handles `worker_env.resolve`.
  """
  @spec handle_request(String.t(), FabricProto.WorkerEnvResolveRequest.t(), map()) ::
          {:ok, FabricProto.WorkerEnvResolveResponse.t()} | {:error, map()}
  def handle_request(agent_uid, %FabricProto.WorkerEnvResolveRequest{}, ctx) do
    result =
      with {:ok, %{principal: principal}} <- Principals.get_agent(agent_uid),
           :active <- principal.status,
           {:ok, operator} <- operator_environment(principal.uid, ctx),
           {:ok, mcp_secret_keys} <- Ankole.AIAgent.mcp_credential_env_keys(),
           {:ok, mcp_env} <- Ankole.Connectors.Tokens.worker(agent_uid, ctx[:turn_ref]) do
        operator = Map.drop(operator, mcp_secret_keys)

        {:ok,
         %FabricProto.WorkerEnvResolveResponse{
           vars: Map.merge(operator, mcp_env),
           operator_vars: operator,
           binding_vars: mcp_env
         }}
      end

    case result do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, error_payload(ctx.request_id, agent_uid, reason)}
      :disabled -> {:error, error_payload(ctx.request_id, agent_uid, :agent_disabled)}
    end
  end

  defp operator_environment(_uid, %{worker: %{runner_id: runner_id}})
       when is_binary(runner_id),
       do: {:ok, %{}}

  defp operator_environment(uid, _ctx),
    do: WorkerEnv.effective_env(uid)

  defp error_payload(request_id, agent_uid, reason) do
    RPCWire.error_payload(request_id, reason,
      fallback_code: "worker_env_resolve_failed",
      message_style: :tuple_inspect,
      details_json: %{"agent_uid" => agent_uid}
    )
  end
end
