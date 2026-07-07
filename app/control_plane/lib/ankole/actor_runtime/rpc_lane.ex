defmodule Ankole.ActorRuntime.RPCLane do
  @moduledoc """
  Dispatches RuntimeFabric RPC requests on the control-plane side.

  Method handlers return method payloads. This module is the only control-plane
  code that wraps those results as `rpc_response` or `rpc_error` envelopes.
  """

  alias Ankole.ActorRuntime.AgentConversationContextBroker
  alias Ankole.ActorRuntime.AIGatewayApiKeyBroker
  alias Ankole.ActorRuntime.AppConfigureBroker
  alias Ankole.ActorRuntime.CodexDelegationBroker
  alias Ankole.ActorRuntime.RPCWire
  alias Ankole.ActorRuntime.SkillRegistryBroker
  alias Ankole.ActorRuntime.SkillOverlayBroker
  alias Ankole.ActorRuntime.TurnRef
  alias Ankole.ActorRuntime.WorkerRouteAuth
  alias Ankole.Memory.RPCBroker, as: MemoryRPCBroker
  alias Ankole.Schedule.RPCBroker

  @method_handlers %{
    "ai_gateway.api_key_for.create_or_find_by_agent" => %{
      kind: :worker_agent,
      module: AIGatewayApiKeyBroker,
      function: :handle_request,
      leading_args: []
    },
    "agent_conversation.context.resolve" => %{
      kind: :turn,
      module: AgentConversationContextBroker,
      function: :handle_request,
      leading_args: [],
      turn_key: :turn,
      effect: :read
    },
    "app_configure.resolve" => %{
      kind: :worker_agent,
      module: AppConfigureBroker,
      function: :handle_request,
      leading_args: []
    },
    "codex.delegation.create" => %{
      kind: :worker_agent,
      module: CodexDelegationBroker,
      function: :handle_create,
      leading_args: []
    },
    "codex.delegation.get" => %{
      kind: :worker_agent,
      module: CodexDelegationBroker,
      function: :handle_get,
      leading_args: []
    },
    "codex.delegation.event.append" => %{
      kind: :worker_agent,
      module: CodexDelegationBroker,
      function: :handle_append_event,
      leading_args: []
    },
    "codex.delegation.status.update" => %{
      kind: :worker_agent,
      module: CodexDelegationBroker,
      function: :handle_update_status,
      leading_args: []
    },
    "memory_note.save" => %{
      kind: :turn,
      module: MemoryRPCBroker,
      function: :handle_request,
      leading_args: ["memory_note.save"],
      turn_key: :turn_ref,
      effect: :write
    },
    "memory_note.update" => %{
      kind: :turn,
      module: MemoryRPCBroker,
      function: :handle_request,
      leading_args: ["memory_note.update"],
      turn_key: :turn_ref,
      effect: :write
    },
    "memory_note.forget" => %{
      kind: :turn,
      module: MemoryRPCBroker,
      function: :handle_request,
      leading_args: ["memory_note.forget"],
      turn_key: :turn_ref,
      effect: :write
    },
    "memory_note.list" => %{
      kind: :turn,
      module: MemoryRPCBroker,
      function: :handle_request,
      leading_args: ["memory_note.list"],
      turn_key: :turn_ref,
      effect: :read
    },
    "memory_search" => %{
      kind: :turn,
      module: MemoryRPCBroker,
      function: :handle_request,
      leading_args: ["memory_search"],
      turn_key: :turn_ref,
      effect: :read
    },
    "memory_browse" => %{
      kind: :turn,
      module: MemoryRPCBroker,
      function: :handle_request,
      leading_args: ["memory_browse"],
      turn_key: :turn_ref,
      effect: :read
    },
    "schedule.check_back_later.create" => %{
      kind: :turn,
      module: RPCBroker,
      function: :handle_request,
      leading_args: ["check_back_later.create"],
      turn_key: :turn_ref,
      effect: :write
    },
    "schedule.cron.list" => %{
      kind: :turn,
      module: RPCBroker,
      function: :handle_request,
      leading_args: ["cron.list"],
      turn_key: :turn_ref,
      effect: :read
    },
    "schedule.cron.get" => %{
      kind: :turn,
      module: RPCBroker,
      function: :handle_request,
      leading_args: ["cron.get"],
      turn_key: :turn_ref,
      effect: :read
    },
    "schedule.cron.runs" => %{
      kind: :turn,
      module: RPCBroker,
      function: :handle_request,
      leading_args: ["cron.runs"],
      turn_key: :turn_ref,
      effect: :read
    },
    "schedule.cron.add" => %{
      kind: :turn,
      module: RPCBroker,
      function: :handle_request,
      leading_args: ["cron.add"],
      turn_key: :turn_ref,
      effect: :write
    },
    "schedule.cron.update" => %{
      kind: :turn,
      module: RPCBroker,
      function: :handle_request,
      leading_args: ["cron.update"],
      turn_key: :turn_ref,
      effect: :write
    },
    "schedule.cron.pause" => %{
      kind: :turn,
      module: RPCBroker,
      function: :handle_request,
      leading_args: ["cron.pause"],
      turn_key: :turn_ref,
      effect: :write
    },
    "schedule.cron.resume" => %{
      kind: :turn,
      module: RPCBroker,
      function: :handle_request,
      leading_args: ["cron.resume"],
      turn_key: :turn_ref,
      effect: :write
    },
    "schedule.cron.remove" => %{
      kind: :turn,
      module: RPCBroker,
      function: :handle_request,
      leading_args: ["cron.remove"],
      turn_key: :turn_ref,
      effect: :write
    },
    "schedule.cron.run" => %{
      kind: :turn,
      module: RPCBroker,
      function: :handle_request,
      leading_args: ["cron.run"],
      turn_key: :turn_ref,
      effect: :write
    },
    "skills.installed.replace" => %{
      kind: :turn,
      module: SkillRegistryBroker,
      function: :handle_replace,
      leading_args: [],
      turn_key: :turn,
      effect: :write
    },
    "skills.overlay.resolve" => %{
      kind: :turn,
      module: SkillOverlayBroker,
      function: :handle_request,
      leading_args: ["resolve"],
      turn_key: :turn,
      effect: :read
    },
    "skills.overlay.replace" => %{
      kind: :turn,
      module: SkillOverlayBroker,
      function: :handle_request,
      leading_args: ["replace"],
      turn_key: :turn,
      effect: :write
    }
  }

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
    case Map.fetch(@method_handlers, method) do
      {:ok,
       %{kind: :worker_agent, module: module, function: function, leading_args: leading_args}} ->
        apply(module, function, leading_args ++ [payload, route])

      {:ok,
       %{
         kind: :turn,
         module: module,
         function: function,
         leading_args: leading_args,
         turn_key: turn_key,
         effect: effect
       }} ->
        dispatch_turn_method(module, function, leading_args, turn_key, effect, payload, route)

      :error ->
        {:error,
         %{
           "code" => "unknown_rpc_method",
           "message" => "unknown RPC method: #{method}",
           "details_json" => %{"method" => method}
         }}
    end
  end

  defp dispatch_turn_method(module, function, leading_args, turn_key, effect, payload, route) do
    with {:ok, turn_ref} <- TurnRef.from_request(payload, turn_key),
         :ok <- WorkerRouteAuth.authorize_turn_route(turn_ref, route, effect) do
      apply(module, function, leading_args ++ [turn_ref, payload, route])
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
