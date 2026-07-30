defmodule Ankole.SignalsGateway.ActorRuntime.RPCLane do
  @moduledoc """
  Dispatches RuntimeFabric RPC requests on the control-plane side.

  `@rpc_operations` is the Elixir side of the cross-language RPC contract:
  one row per operation mapping the wire method to its broker function, scope,
  and generated request message module. Payload shapes are the generated
  messages from `app/kernel/proto/ankole/runtime_fabric/v1/rpc.proto`. The
  turn fence and worker_agent subject travel on the `RPCRequest` frame:
  turn-scoped operations are authorized through `WorkerRouteAuth` before the
  payload is decoded, and `worker_agent` operations trust the frame
  `agent_uid` by design.

  The Bun side of the contract lives in `app/agent_computer/src/lanes/rpc_lane.ts`;
  both sides are pinned to `app/kernel/proto/ankole/runtime_fabric/v1/rpc_methods.json`
  by package-local parity tests. Adding an operation means: messages in
  `rpc.proto` plus `bun run gen:proto`, the Bun table entries plus
  `bun run gen:rpc-contract`, and one dispatch row plus one broker function
  clause here.

  This module is the single control-plane codec boundary for RPC payloads.
  Brokers receive the decoded request struct plus a `ctx` map carrying the
  frame facts (`route`, `request_id`) and return either a response struct
  (encoded directly), a plain map (wrapped as model-facing
  `JSONPassthroughResponse`), or an error payload map (wrapped as
  `rpc_error`).
  """

  alias Ankole.AutomationJobs.RPCBroker, as: AutomationJobRPCBroker
  alias Ankole.Brain.RPCBroker, as: BrainRPCBroker
  alias Ankole.Kernel.RuntimeFabric
  alias Ankole.Logging
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.Schedule.RPCBroker, as: ScheduleRPCBroker
  alias Ankole.SignalsGateway.ActorRuntime.AgentConversationContextBroker
  alias Ankole.SignalsGateway.ActorRuntime.AgentPluginBroker
  alias Ankole.SignalsGateway.ActorRuntime.AIGatewayAPIKeyBroker
  alias Ankole.SignalsGateway.ActorRuntime.AppConfigureBroker
  alias Ankole.SignalsGateway.ActorRuntime.BackgroundAgentJobBroker
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire
  alias Ankole.SignalsGateway.ActorRuntime.SkillOverlayBroker
  alias Ankole.SignalsGateway.ActorRuntime.SkillRegistryBroker
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SignalsGateway.ActorRuntime.WorkerEnvBroker
  alias Ankole.SignalsGateway.ActorRuntime.WorkerRouteAuth
  alias Ankole.SignalsGateway.Webhooks.RPCBroker, as: WebhookRPCBroker

  @typedoc "Authorization scope of one operation; turn scopes carry the WorkerRouteAuth effect."
  @type scope :: :worker_agent | :turn_read | :turn_write

  @typedoc "Frame facts handed to every broker beside the decoded request."
  @type ctx :: %{route: String.t(), request_id: String.t()}

  @rpc_operations %{
    "ai_gateway.api_key_for.create_or_find_by_agent" =>
      {AIGatewayAPIKeyBroker, :handle_request, :worker_agent, FabricProto.AIGatewayAPIKeyRequest},
    "agent_conversation.context.resolve" =>
      {AgentConversationContextBroker, :handle_request, :turn_read,
       FabricProto.AgentConversationContextRequest},
    "app_configure.resolve" =>
      {AppConfigureBroker, :handle_request, :worker_agent, FabricProto.AppConfigureResolveRequest},
    "agent_plugin.list" =>
      {AgentPluginBroker, :handle_list, :turn_read, FabricProto.AgentPluginListRequest},
    "automation_job.create" =>
      {AutomationJobRPCBroker, :handle_create, :turn_write,
       FabricProto.AutomationJobCreateRequest},
    "automation_job.list" =>
      {AutomationJobRPCBroker, :handle_list, :turn_read, FabricProto.AutomationJobListRequest},
    "automation_job.show" =>
      {AutomationJobRPCBroker, :handle_show, :turn_read, FabricProto.AutomationJobShowRequest},
    "automation_job.cancel" =>
      {AutomationJobRPCBroker, :handle_cancel, :turn_write,
       FabricProto.AutomationJobTargetRequest},
    "automation_job.emit" =>
      {AutomationJobRPCBroker, :handle_emit, :worker_agent, FabricProto.AutomationJobEmitRequest},
    "background_agent_job.create" =>
      {BackgroundAgentJobBroker, :handle_create, :turn_write,
       FabricProto.BackgroundAgentJobCreateRequest},
    "background_agent_job.get" =>
      {BackgroundAgentJobBroker, :handle_get, :turn_read,
       FabricProto.BackgroundAgentJobGetRequest},
    "background_agent_job.list" =>
      {BackgroundAgentJobBroker, :handle_list, :turn_read,
       FabricProto.BackgroundAgentJobListRequest},
    "background_agent_job.message.send" =>
      {BackgroundAgentJobBroker, :handle_message_send, :turn_write,
       FabricProto.BackgroundAgentJobMessageSendRequest},
    "background_agent_job.message.result" =>
      {BackgroundAgentJobBroker, :handle_message_result, :turn_read,
       FabricProto.BackgroundAgentJobMessageResultRequest},
    "background_agent_job.respawn" =>
      {BackgroundAgentJobBroker, :handle_respawn, :turn_write,
       FabricProto.BackgroundAgentJobRespawnRequest},
    "background_agent_job.stop" =>
      {BackgroundAgentJobBroker, :handle_stop, :turn_write,
       FabricProto.BackgroundAgentJobStopRequest},
    "background_agent_job.turn.upsert" =>
      {BackgroundAgentJobBroker, :handle_upsert_turn, :turn_write,
       FabricProto.BackgroundAgentJobTurnUpsertRequest},
    "background_agent_job.status.update" =>
      {BackgroundAgentJobBroker, :handle_update_status, :turn_write,
       FabricProto.BackgroundAgentJobStatusUpdateRequest},
    "memory_search" =>
      {BrainRPCBroker, :handle_search, :turn_read, FabricProto.MemorySearchRequest},
    "memory_open" => {BrainRPCBroker, :handle_open, :turn_read, FabricProto.MemoryOpenRequest},
    "memory_update" =>
      {BrainRPCBroker, :handle_update, :turn_write, FabricProto.MemoryUpdateRequest},
    "memory_browse" =>
      {BrainRPCBroker, :handle_browse, :turn_read, FabricProto.MemoryBrowseRequest},
    "memory_health_check" =>
      {BrainRPCBroker, :handle_health_check, :turn_read, FabricProto.MemoryHealthCheckRequest},
    "schedule.check_back_later.create" =>
      {ScheduleRPCBroker, :handle_check_back_later_create, :turn_write,
       FabricProto.ScheduleCheckBackLaterCreateRequest},
    "schedule.check_back_later.list" =>
      {ScheduleRPCBroker, :handle_check_back_later_list, :turn_read,
       FabricProto.ScheduleCheckBackLaterListRequest},
    "schedule.check_back_later.get" =>
      {ScheduleRPCBroker, :handle_check_back_later_get, :turn_read,
       FabricProto.ScheduleCheckBackLaterTargetRequest},
    "schedule.check_back_later.update" =>
      {ScheduleRPCBroker, :handle_check_back_later_update, :turn_write,
       FabricProto.ScheduleCheckBackLaterUpdateRequest},
    "schedule.check_back_later.cancel" =>
      {ScheduleRPCBroker, :handle_check_back_later_cancel, :turn_write,
       FabricProto.ScheduleCheckBackLaterTargetRequest},
    "schedule.cron.list" =>
      {ScheduleRPCBroker, :handle_cron_list, :turn_read, FabricProto.ScheduleCronListRequest},
    "schedule.cron.get" =>
      {ScheduleRPCBroker, :handle_cron_get, :turn_read, FabricProto.ScheduleCronTargetRequest},
    "schedule.cron.runs" =>
      {ScheduleRPCBroker, :handle_cron_runs, :turn_read, FabricProto.ScheduleCronRunsRequest},
    "schedule.cron.add" =>
      {ScheduleRPCBroker, :handle_cron_add, :turn_write, FabricProto.ScheduleCronAddRequest},
    "schedule.cron.update" =>
      {ScheduleRPCBroker, :handle_cron_update, :turn_write, FabricProto.ScheduleCronUpdateRequest},
    "schedule.cron.pause" =>
      {ScheduleRPCBroker, :handle_cron_pause, :turn_write, FabricProto.ScheduleCronTargetRequest},
    "schedule.cron.resume" =>
      {ScheduleRPCBroker, :handle_cron_resume, :turn_write, FabricProto.ScheduleCronTargetRequest},
    "schedule.cron.remove" =>
      {ScheduleRPCBroker, :handle_cron_remove, :turn_write, FabricProto.ScheduleCronTargetRequest},
    "schedule.cron.run" =>
      {ScheduleRPCBroker, :handle_cron_run, :turn_write, FabricProto.ScheduleCronRunRequest},
    "webhook.endpoint.create" =>
      {WebhookRPCBroker, :handle_create, :turn_write, FabricProto.WebhookEndpointCreateRequest},
    "webhook.endpoint.list" =>
      {WebhookRPCBroker, :handle_list, :turn_read, FabricProto.WebhookEndpointListRequest},
    "webhook.endpoint.cancel" =>
      {WebhookRPCBroker, :handle_cancel, :turn_write, FabricProto.WebhookEndpointTargetRequest},
    "skills.installed.replace" =>
      {SkillRegistryBroker, :handle_replace, :turn_write,
       FabricProto.InstalledSkillReplaceRequest},
    "skills.overlay.resolve" =>
      {SkillOverlayBroker, :handle_resolve, :turn_read, FabricProto.SkillOverlayResolveRequest},
    "skills.overlay.append" =>
      {SkillOverlayBroker, :handle_append, :turn_write, FabricProto.SkillOverlayAppendRequest},
    "skills.overlay.replace" =>
      {SkillOverlayBroker, :handle_replace, :turn_write, FabricProto.SkillOverlayReplaceRequest},
    "worker_env.resolve" =>
      {WorkerEnvBroker, :handle_request, :worker_agent, FabricProto.WorkerEnvResolveRequest}
  }

  @doc false
  @spec operations() :: %{String.t() => {module(), atom(), scope(), module()}}
  def operations, do: @rpc_operations

  @spec handle_request(FabricProto.RPCRequest.t(), String.t()) ::
          {:ok, FabricProto.Envelope.t()} | {:error, term()}
  def handle_request(%FabricProto.RPCRequest{} = request, route) when is_binary(route) do
    request_id = presence(request.request_id) || "rpc-#{Ecto.UUID.generate()}"
    ctx = %{route: route, request_id: request_id}

    case dispatch_method_safely(request, ctx) do
      {:ok, %_{} = response_struct} ->
        {:ok, rpc_response_envelope(request_id, encode_payload(response_struct))}

      {:ok, response_payload} when is_map(response_payload) ->
        passthrough = %FabricProto.JSONPassthroughResponse{
          body_json: Torque.encode!(response_payload)
        }

        {:ok, rpc_response_envelope(request_id, encode_payload(passthrough))}

      {:error, error_payload} when is_map(error_payload) ->
        {:ok, rpc_error_envelope(request_id, error_payload)}
    end
  end

  def handle_request(_request, _route), do: {:error, :invalid_rpc_request}

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  # RuntimeFabric's Broker owns the shared ROUTER for every worker. A defect or
  # unexpected database failure in one semantic method must fail that RPC, not
  # terminate the transport owner and disconnect the whole worker pool.
  defp dispatch_method_safely(request, ctx) do
    case dispatch_method(request, ctx) do
      {:ok, %_{}} = result ->
        result

      {:ok, response_payload} = result when is_map(response_payload) ->
        result

      {:error, error_payload} = result when is_map(error_payload) ->
        result

      _unexpected ->
        log_invalid_handler_result(request.method, ctx.route)
        {:error, handler_failure_payload(ctx.request_id, request.method)}
    end
  rescue
    exception ->
      log_handler_failure(request.method, ctx.route, :error, exception, __STACKTRACE__)
      {:error, handler_failure_payload(ctx.request_id, request.method)}
  catch
    kind, reason ->
      log_handler_failure(request.method, ctx.route, kind, reason, __STACKTRACE__)
      {:error, handler_failure_payload(ctx.request_id, request.method)}
  end

  defp dispatch_method(request, ctx) do
    case Map.fetch(@rpc_operations, request.method) do
      {:ok, {module, function, :worker_agent, request_mod}} ->
        with {:ok, payload} <- decode_payload(request_mod, request.payload, ctx) do
          apply(module, function, [presence(request.agent_uid), payload, ctx])
        end

      {:ok, {module, function, scope, request_mod}} ->
        with {:ok, turn_ref} <- request_turn_ref(request, ctx),
             :ok <- authorize_turn(turn_ref, ctx, scope_effect(scope)),
             {:ok, payload} <- decode_payload(request_mod, request.payload, ctx) do
          apply(module, function, [turn_ref, payload, ctx])
        end

      :error ->
        {:error,
         %{
           "code" => "unknown_rpc_method",
           "message" => "unknown RPC method: #{request.method}",
           "details_json" => %{"method" => request.method}
         }}
    end
  end

  defp scope_effect(:turn_read), do: :read
  defp scope_effect(:turn_write), do: :write

  defp request_turn_ref(request, ctx) do
    case TurnRef.from_proto(request.turn) do
      {:ok, turn_ref} -> {:ok, turn_ref}
      {:error, reason} -> {:error, auth_error_payload(ctx, reason)}
    end
  end

  defp authorize_turn(turn_ref, ctx, effect) do
    case WorkerRouteAuth.authorize_turn_route(turn_ref, ctx.route, effect) do
      :ok -> :ok
      {:error, reason} -> {:error, auth_error_payload(ctx, reason)}
    end
  end

  defp decode_payload(request_mod, payload, ctx) do
    case request_mod.decode(payload) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, reason} ->
        {:error,
         %{
           "request_id" => ctx.request_id,
           "code" => "invalid_rpc_payload",
           "message" => "RPC payload does not decode as #{inspect(request_mod)}",
           "details_json" => %{"reason" => inspect(reason)}
         }}
    end
  end

  defp encode_payload(struct) do
    {iodata, _size} = struct.__struct__.encode!(struct)
    IO.iodata_to_binary(iodata)
  end

  defp rpc_response_envelope(request_id, payload) do
    %FabricProto.Envelope{
      protocol_version: RuntimeFabric.protocol_version(),
      message_id: "rpc-response-#{Ecto.UUID.generate()}",
      correlation_id: request_id,
      lane: :LANE_RPC,
      sent_at_unix_ms: System.system_time(:millisecond),
      durability: :CONTROL_EPHEMERAL,
      body:
        {:rpc_response,
         %FabricProto.RPCResponse{
           request_id: request_id,
           payload: payload
         }}
    }
  end

  defp rpc_error_envelope(request_id, error_payload) do
    %FabricProto.Envelope{
      protocol_version: RuntimeFabric.protocol_version(),
      message_id: "rpc-error-#{Ecto.UUID.generate()}",
      correlation_id: request_id,
      lane: :LANE_RPC,
      sent_at_unix_ms: System.system_time(:millisecond),
      durability: :CONTROL_EPHEMERAL,
      body:
        {:rpc_error,
         %FabricProto.RPCError{
           request_id: RPCWire.text(error_payload, "request_id") || request_id,
           code: RPCWire.text(error_payload, "code") || "rpc_request_failed",
           message: RPCWire.text(error_payload, "message") || "RPC request failed",
           details_json: Torque.encode!(RPCWire.map_value(error_payload, "details_json", %{}))
         }}
    }
  end

  defp auth_error_payload(ctx, reason) do
    RPCWire.error_payload(ctx.request_id, reason,
      fallback_code: "rpc_request_failed",
      details_json: %{"reason" => inspect(reason)}
    )
  end

  defp handler_failure_payload(request_id, method) do
    %{
      "request_id" => request_id,
      "code" => "rpc_handler_failed",
      "message" => "RPC handler failed",
      "details_json" => %{"method" => method}
    }
  end

  defp log_handler_failure(method, route, kind, reason, stacktrace) do
    Logging.error(
      "runtime_fabric.rpc_handler_failed",
      "runtime fabric rpc handler failed",
      %{
        method: method,
        route: route,
        reason: Exception.format(kind, reason, stacktrace)
      }
    )
  end

  defp log_invalid_handler_result(method, route) do
    Logging.error(
      "runtime_fabric.rpc_handler_invalid_result",
      "runtime fabric rpc handler returned an invalid result",
      %{
        method: method,
        route: route
      }
    )
  end
end
