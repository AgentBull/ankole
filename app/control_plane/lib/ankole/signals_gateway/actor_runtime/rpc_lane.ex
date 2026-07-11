defmodule Ankole.SignalsGateway.ActorRuntime.RPCLane do
  @moduledoc """
  Dispatches RuntimeFabric RPC requests on the control-plane side.

  `@rpc_operations` is the Elixir side of the cross-language RPC contract:
  one row per operation mapping the wire method to its broker function and
  scope. Turn-scoped operations read the turn fence from the payload `turn`
  key and are authorized through `WorkerRouteAuth` with the effect carried by
  the scope atom; `worker_agent` operations carry no turn fence by design.

  The Bun side of the contract lives in `app/agent_computer/src/lanes/rpc_lane.ts`;
  both sides are pinned to `app/kernel/proto/ankole/runtime_fabric/v1/rpc_methods.json`
  by package-local parity tests. Adding an operation means one row here plus one
  broker function, and the matching Bun contract entries.

  Method handlers return method payloads. This module is the only control-plane
  code that wraps those results as `rpc_response` or `rpc_error` envelopes.
  """

  alias Ankole.SignalsGateway.ActorRuntime.AgentConversationContextBroker
  alias Ankole.SignalsGateway.ActorRuntime.AIGatewayApiKeyBroker
  alias Ankole.SignalsGateway.ActorRuntime.AppConfigureBroker
  alias Ankole.SignalsGateway.ActorRuntime.CodexAccountBroker
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire
  alias Ankole.SignalsGateway.ActorRuntime.SkillRegistryBroker
  alias Ankole.SignalsGateway.ActorRuntime.SkillOverlayBroker
  alias Ankole.SignalsGateway.ActorRuntime.SubagentDelegationBroker
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SignalsGateway.ActorRuntime.WorkerRouteAuth
  alias Ankole.Memory.RPCBroker, as: MemoryRPCBroker
  alias Ankole.Schedule.RPCBroker, as: ScheduleRPCBroker

  @typedoc "Authorization scope of one operation; turn scopes carry the WorkerRouteAuth effect."
  @type scope :: :worker_agent | :turn_read | :turn_write

  @rpc_operations %{
    "ai_gateway.api_key_for.create_or_find_by_agent" =>
      {AIGatewayApiKeyBroker, :handle_request, :worker_agent},
    "agent_conversation.context.resolve" =>
      {AgentConversationContextBroker, :handle_request, :turn_read},
    "app_configure.resolve" => {AppConfigureBroker, :handle_request, :worker_agent},
    "codex.account.resolve" => {CodexAccountBroker, :handle_resolve, :turn_read},
    "codex.account.auth.update" => {CodexAccountBroker, :handle_update_auth, :turn_write},
    "subagent.delegation.create" => {SubagentDelegationBroker, :handle_create, :turn_write},
    "subagent.delegation.get" => {SubagentDelegationBroker, :handle_get, :turn_read},
    "subagent.delegation.list" => {SubagentDelegationBroker, :handle_list, :turn_read},
    "subagent.delegation.steer" => {SubagentDelegationBroker, :handle_steer, :turn_write},
    "subagent.delegation.stop" => {SubagentDelegationBroker, :handle_stop, :turn_write},
    "subagent.delegation.event.append" =>
      {SubagentDelegationBroker, :handle_append_events, :turn_write},
    "subagent.delegation.status.update" =>
      {SubagentDelegationBroker, :handle_update_status, :turn_write},
    "memory_note.save" => {MemoryRPCBroker, :handle_note_save, :turn_write},
    "memory_note.update" => {MemoryRPCBroker, :handle_note_update, :turn_write},
    "memory_note.forget" => {MemoryRPCBroker, :handle_note_forget, :turn_write},
    "memory_note.list" => {MemoryRPCBroker, :handle_note_list, :turn_read},
    "memory_search" => {MemoryRPCBroker, :handle_search, :turn_read},
    "memory_browse" => {MemoryRPCBroker, :handle_browse, :turn_read},
    "schedule.check_back_later.create" =>
      {ScheduleRPCBroker, :handle_check_back_later_create, :turn_write},
    "schedule.cron.list" => {ScheduleRPCBroker, :handle_cron_list, :turn_read},
    "schedule.cron.get" => {ScheduleRPCBroker, :handle_cron_get, :turn_read},
    "schedule.cron.runs" => {ScheduleRPCBroker, :handle_cron_runs, :turn_read},
    "schedule.cron.add" => {ScheduleRPCBroker, :handle_cron_add, :turn_write},
    "schedule.cron.update" => {ScheduleRPCBroker, :handle_cron_update, :turn_write},
    "schedule.cron.pause" => {ScheduleRPCBroker, :handle_cron_pause, :turn_write},
    "schedule.cron.resume" => {ScheduleRPCBroker, :handle_cron_resume, :turn_write},
    "schedule.cron.remove" => {ScheduleRPCBroker, :handle_cron_remove, :turn_write},
    "schedule.cron.run" => {ScheduleRPCBroker, :handle_cron_run, :turn_write},
    "skills.installed.replace" => {SkillRegistryBroker, :handle_replace, :turn_write},
    "skills.overlay.resolve" => {SkillOverlayBroker, :handle_resolve, :turn_read},
    "skills.overlay.replace" => {SkillOverlayBroker, :handle_replace, :turn_write}
  }

  @doc false
  @spec operations() :: %{String.t() => {module(), atom(), scope()}}
  def operations, do: @rpc_operations

  @spec handle_request(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def handle_request(request, route) when is_map(request) and is_binary(route) do
    request_id = RPCWire.text(request, "request_id") || "rpc-#{Ecto.UUID.generate()}"
    method = RPCWire.text(request, "method") || ""
    payload = Map.put_new(request_payload(request), "request_id", request_id)

    case dispatch_method(method, payload, route) do
      {:ok, response_payload} ->
        {:ok, rpc_response_envelope(request_id, response_payload)}

      {:error, error_payload} when is_map(error_payload) ->
        {:ok, rpc_error_envelope(request_id, error_payload)}
    end
  end

  def handle_request(_request, _route), do: {:error, :invalid_rpc_request}

  defp dispatch_method(method, payload, route) do
    case Map.fetch(@rpc_operations, method) do
      {:ok, {module, function, :worker_agent}} ->
        apply(module, function, [payload, route])

      {:ok, {module, function, scope}} ->
        dispatch_turn_method(module, function, scope_effect(scope), payload, route)

      :error ->
        {:error,
         %{
           "code" => "unknown_rpc_method",
           "message" => "unknown RPC method: #{method}",
           "details_json" => %{"method" => method}
         }}
    end
  end

  defp scope_effect(:turn_read), do: :read
  defp scope_effect(:turn_write), do: :write

  defp dispatch_turn_method(module, function, effect, payload, route) do
    with {:ok, turn_ref} <- TurnRef.from_request(payload),
         :ok <- WorkerRouteAuth.authorize_turn_route(turn_ref, route, effect) do
      apply(module, function, [turn_ref, payload, route])
    else
      {:error, reason} -> {:error, error_payload(payload, reason)}
    end
  end

  defp rpc_response_envelope(request_id, payload) do
    %{
      "protocol_version" => 1,
      "message_id" => "rpc-response-#{Ecto.UUID.generate()}",
      "correlation_id" => request_id,
      "lane" => "LANE_RPC",
      "durability" => "CONTROL_EPHEMERAL",
      "body" => %{
        "type" => "rpc_response",
        "rpc_response" => %{
          "request_id" => request_id,
          "payload_json" => payload
        }
      }
    }
  end

  defp rpc_error_envelope(request_id, error_payload) do
    %{
      "protocol_version" => 1,
      "message_id" => "rpc-error-#{Ecto.UUID.generate()}",
      "correlation_id" => request_id,
      "lane" => "LANE_RPC",
      "durability" => "CONTROL_EPHEMERAL",
      "body" => %{
        "type" => "rpc_error",
        "rpc_error" => %{
          "request_id" => RPCWire.text(error_payload, "request_id") || request_id,
          "code" => RPCWire.text(error_payload, "code") || "rpc_request_failed",
          "message" => RPCWire.text(error_payload, "message") || "RPC request failed",
          "details_json" => RPCWire.map_value(error_payload, "details_json", %{})
        }
      }
    }
  end

  defp request_payload(%{"payload_json" => payload}) when is_map(payload), do: payload
  defp request_payload(%{payload_json: payload}) when is_map(payload), do: payload
  defp request_payload(_request), do: %{}

  defp error_payload(payload, reason) do
    RPCWire.error_payload(RPCWire.text(payload, "request_id") || "", reason,
      fallback_code: "rpc_request_failed",
      details_json: %{"reason" => inspect(reason)}
    )
  end
end
