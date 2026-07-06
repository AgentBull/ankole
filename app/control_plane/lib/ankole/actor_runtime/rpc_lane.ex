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
  alias Ankole.ActorRuntime.SkillRegistryBroker
  alias Ankole.ActorRuntime.SkillOverlayBroker
  alias Ankole.ActorRuntime.TurnRef
  alias Ankole.ActorRuntime.WorkerRouteAuth
  alias Ankole.Memory.RPCBroker, as: MemoryRPCBroker
  alias Ankole.Schedule.RPCBroker

  @method_handlers %{
    "ai_gateway.api_key_for.create_or_find_by_agent" =>
      {:plain, AIGatewayApiKeyBroker, :handle_request, []},
    "agent_conversation.context.resolve" =>
      {:turn, AgentConversationContextBroker, :handle_request, [], :turn, :read},
    "app_configure.resolve" => {:plain, AppConfigureBroker, :handle_request, []},
    "codex.delegation.create" => {:plain, CodexDelegationBroker, :handle_create, []},
    "codex.delegation.get" => {:plain, CodexDelegationBroker, :handle_get, []},
    "codex.delegation.event.append" => {:plain, CodexDelegationBroker, :handle_append_event, []},
    "codex.delegation.status.update" =>
      {:plain, CodexDelegationBroker, :handle_update_status, []},
    "memory_note.save" =>
      {:turn, MemoryRPCBroker, :handle_request, ["memory_note.save"], :turn_ref, :write},
    "memory_note.update" =>
      {:turn, MemoryRPCBroker, :handle_request, ["memory_note.update"], :turn_ref, :write},
    "memory_note.forget" =>
      {:turn, MemoryRPCBroker, :handle_request, ["memory_note.forget"], :turn_ref, :write},
    "memory_note.list" =>
      {:turn, MemoryRPCBroker, :handle_request, ["memory_note.list"], :turn_ref, :read},
    "memory_search" =>
      {:turn, MemoryRPCBroker, :handle_request, ["memory_search"], :turn_ref, :read},
    "memory_browse" =>
      {:turn, MemoryRPCBroker, :handle_request, ["memory_browse"], :turn_ref, :read},
    "schedule.check_back_later.create" =>
      {:turn, RPCBroker, :handle_request, ["check_back_later.create"], :turn_ref, :write},
    "schedule.cron.list" => {:turn, RPCBroker, :handle_request, ["cron.list"], :turn_ref, :read},
    "schedule.cron.get" => {:turn, RPCBroker, :handle_request, ["cron.get"], :turn_ref, :read},
    "schedule.cron.runs" => {:turn, RPCBroker, :handle_request, ["cron.runs"], :turn_ref, :read},
    "schedule.cron.add" => {:turn, RPCBroker, :handle_request, ["cron.add"], :turn_ref, :write},
    "schedule.cron.update" =>
      {:turn, RPCBroker, :handle_request, ["cron.update"], :turn_ref, :write},
    "schedule.cron.pause" =>
      {:turn, RPCBroker, :handle_request, ["cron.pause"], :turn_ref, :write},
    "schedule.cron.resume" =>
      {:turn, RPCBroker, :handle_request, ["cron.resume"], :turn_ref, :write},
    "schedule.cron.remove" =>
      {:turn, RPCBroker, :handle_request, ["cron.remove"], :turn_ref, :write},
    "schedule.cron.run" => {:turn, RPCBroker, :handle_request, ["cron.run"], :turn_ref, :write},
    "skills.installed.replace" =>
      {:turn, SkillRegistryBroker, :handle_replace, [], :turn, :write},
    "skills.overlay.resolve" =>
      {:turn, SkillOverlayBroker, :handle_request, ["resolve"], :turn, :read},
    "skills.overlay.replace" =>
      {:turn, SkillOverlayBroker, :handle_request, ["replace"], :turn, :write}
  }

  @spec handle_request(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def handle_request(request, route) when is_map(request) and is_binary(route) do
    request_id = text(request, "request_id") || "rpc-#{Ecto.UUID.generate()}"
    method = text(request, "method") || ""
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
      {:ok, {:plain, module, function, leading_args}} ->
        apply(module, function, leading_args ++ [payload, route])

      {:ok, {:turn, module, function, leading_args, turn_key, effect}} ->
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
          "request_id" => text(error_payload, "request_id") || request_id,
          "code" => text(error_payload, "code") || "rpc_request_failed",
          "message" => text(error_payload, "message") || "RPC request failed",
          "details_json" => map_value(error_payload, "details_json")
        }
      }
    }
  end

  defp request_payload(%{"payload_json" => payload}) when is_map(payload), do: payload
  defp request_payload(%{payload_json: payload}) when is_map(payload), do: payload
  defp request_payload(_request), do: %{}

  defp map_value(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_map(value) -> value
      _value -> %{}
    end
  end

  defp error_payload(payload, reason) do
    %{
      "request_id" => text(payload, "request_id") || "",
      "code" => error_code(reason),
      "message" => error_message(reason),
      "details_json" => %{"reason" => inspect(reason)}
    }
  end

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "rpc_request_failed"

  defp error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_message({reason, details}) when is_atom(reason), do: "#{reason}: #{inspect(details)}"
  defp error_message(reason), do: inspect(reason)

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
