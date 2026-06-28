defmodule Ankole.ActorRuntime.RPCLane do
  @moduledoc """
  Dispatches RuntimeFabric RPC requests on the control-plane side.

  Method handlers return method payloads. This module is the only control-plane
  code that wraps those results as `rpc_response` or `rpc_error` envelopes.
  """

  alias Ankole.ActorRuntime.AgentConversationContextBroker
  alias Ankole.ActorRuntime.AIGatewayApiKeyBroker
  alias Ankole.ActorRuntime.ConversationHistoryBroker
  alias Ankole.ActorRuntime.ConversationSummaryBroker
  alias Ankole.ActorRuntime.SkillOverlayBroker
  alias Ankole.ActorRuntime.WorkerRouteAuth
  alias Ankole.Schedule.RPCBroker

  @method_handlers %{
    "ai_gateway.api_key_for.create_or_find_by_agent" =>
      {AIGatewayApiKeyBroker, :handle_request, []},
    "agent_conversation.context.resolve" => {AgentConversationContextBroker, :handle_request, []},
    "conversation.history.resolve" => {ConversationHistoryBroker, :handle_request, []},
    "conversation.summary.commit" => {ConversationSummaryBroker, :handle_request, []},
    "schedule.check_back_later.create" =>
      {RPCBroker, :handle_request,
       ["check_back_later.create", &WorkerRouteAuth.authorize_turn_route/3]},
    "schedule.cron.list" =>
      {RPCBroker, :handle_request, ["cron.list", &WorkerRouteAuth.authorize_turn_route/3]},
    "schedule.cron.get" =>
      {RPCBroker, :handle_request, ["cron.get", &WorkerRouteAuth.authorize_turn_route/3]},
    "schedule.cron.runs" =>
      {RPCBroker, :handle_request, ["cron.runs", &WorkerRouteAuth.authorize_turn_route/3]},
    "schedule.cron.add" =>
      {RPCBroker, :handle_request, ["cron.add", &WorkerRouteAuth.authorize_turn_route/3]},
    "schedule.cron.update" =>
      {RPCBroker, :handle_request, ["cron.update", &WorkerRouteAuth.authorize_turn_route/3]},
    "schedule.cron.pause" =>
      {RPCBroker, :handle_request, ["cron.pause", &WorkerRouteAuth.authorize_turn_route/3]},
    "schedule.cron.resume" =>
      {RPCBroker, :handle_request, ["cron.resume", &WorkerRouteAuth.authorize_turn_route/3]},
    "schedule.cron.remove" =>
      {RPCBroker, :handle_request, ["cron.remove", &WorkerRouteAuth.authorize_turn_route/3]},
    "schedule.cron.run" =>
      {RPCBroker, :handle_request, ["cron.run", &WorkerRouteAuth.authorize_turn_route/3]},
    "skills.overlay.resolve" => {SkillOverlayBroker, :handle_request, ["resolve"]},
    "skills.overlay.replace" => {SkillOverlayBroker, :handle_request, ["replace"]},
    "skills.overlay.clear" => {SkillOverlayBroker, :handle_request, ["clear"]}
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
      {:ok, {module, function, leading_args}} ->
        apply(module, function, leading_args ++ [payload, route])

      :error ->
        {:error,
         %{
           "code" => "unknown_rpc_method",
           "message" => "unknown RPC method: #{method}",
           "details_json" => %{"method" => method}
         }}
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
