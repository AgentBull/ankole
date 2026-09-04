defmodule Ankole.SignalsGateway.ActorRuntime.RPCLane do
  @moduledoc """
  Dispatches RuntimeFabric RPC requests on the control-plane side.

  `@rpc_operations` is the Elixir side of the cross-language RPC contract:
  one row per operation mapping the wire method to its broker function, scope,
  and generated request and response message modules. Payload shapes are the
  generated messages from `app/kernel/proto/ankole/runtime_fabric/v1/rpc.proto`.
  The turn fence and worker_agent subject travel on the `RPCRequest` frame:
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
  frame facts (`route`, `request_id`). A response struct must match the row's
  response module. A plain map is valid only for a row whose response module is
  `JSONPassthroughResponse`; this module wraps that map for the model. Error
  payload maps become `rpc_error` frames.
  """

  alias Ankole.AutomationJobs.RPCBroker, as: AutomationJobRPCBroker
  alias Ankole.Logging
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.Schedule.RPCBroker, as: ScheduleRPCBroker
  alias Ankole.SignalsGateway.ActorRuntime.AgentConversationContextBroker
  alias Ankole.SignalsGateway.ActorRuntime.ActorTurnCompletionBroker
  alias Ankole.SignalsGateway.ActorRuntime.AIGatewayAPIKeyBroker
  alias Ankole.SignalsGateway.ActorRuntime.AppConfigureBroker
  alias Ankole.SignalsGateway.ActorRuntime.BackgroundAgentJobBroker
  alias Ankole.SignalsGateway.ActorRuntime.ObservabilityBroker
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire
  alias Ankole.SignalsGateway.ActorRuntime.SignalChannelBroker
  alias Ankole.SignalsGateway.ActorRuntime.SkillOverlayBroker
  alias Ankole.SignalsGateway.ActorRuntime.SkillRegistryBroker
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SignalsGateway.ActorRuntime.WorkerEnvBroker
  alias Ankole.SignalsGateway.ActorRuntime.WorkflowBroker
  alias Ankole.SignalsGateway.ActorRuntime.WorkerRouteAuth
  alias Ankole.SignalsGateway.Webhooks.RPCBroker, as: WebhookRPCBroker

  @typedoc "Authorization scope of one operation; turn scopes carry the WorkerRouteAuth effect."
  @type scope :: :worker_agent | :turn_read | :turn_write | :turn_complete

  @typedoc "Frame facts handed to every broker beside the decoded request."
  @type ctx :: %{route: String.t(), request_id: String.t()}

  @rpc_operations %{
    "ai_gateway.api_key_for.create_or_find_by_agent" =>
      {AIGatewayAPIKeyBroker, :handle_request, :worker_agent, FabricProto.AIGatewayAPIKeyRequest,
       FabricProto.AIGatewayAPIKeyResponse},
    "agent_conversation.context.resolve" =>
      {AgentConversationContextBroker, :handle_request, :turn_read,
       FabricProto.AgentConversationContextRequest, FabricProto.AgentConversationContextResponse},
    "actor_turn.abort" =>
      {ActorTurnCompletionBroker, :handle_abort, :turn_complete,
       FabricProto.ActorTurnAbortRequest, FabricProto.ActorTurnAbortResponse},
    "actor_turn.complete" =>
      {ActorTurnCompletionBroker, :handle_complete, :turn_complete,
       FabricProto.ActorTurnCompleteRequest, FabricProto.ActorTurnCompleteResponse},
    "actor_turn.noop" =>
      {ActorTurnCompletionBroker, :handle_noop, :turn_complete, FabricProto.ActorTurnNoopRequest,
       FabricProto.ActorTurnNoopResponse},
    "app_configure.resolve" =>
      {AppConfigureBroker, :handle_request, :worker_agent, FabricProto.AppConfigureResolveRequest,
       FabricProto.AppConfigureResolveResponse},
    "automation_job.create" =>
      {AutomationJobRPCBroker, :handle_create, :turn_write,
       FabricProto.AutomationJobCreateRequest, FabricProto.JSONPassthroughResponse},
    "automation_job.list" =>
      {AutomationJobRPCBroker, :handle_list, :turn_read, FabricProto.AutomationJobListRequest,
       FabricProto.JSONPassthroughResponse},
    "automation_job.show" =>
      {AutomationJobRPCBroker, :handle_show, :turn_read, FabricProto.AutomationJobShowRequest,
       FabricProto.JSONPassthroughResponse},
    "automation_job.cancel" =>
      {AutomationJobRPCBroker, :handle_cancel, :turn_write,
       FabricProto.AutomationJobTargetRequest, FabricProto.JSONPassthroughResponse},
    "automation_job.emit" =>
      {AutomationJobRPCBroker, :handle_emit, :worker_agent, FabricProto.AutomationJobEmitRequest,
       FabricProto.AutomationJobEmitResponse},
    "background_agent_job.create" =>
      {BackgroundAgentJobBroker, :handle_create, :turn_write,
       FabricProto.BackgroundAgentJobCreateRequest, FabricProto.BackgroundAgentJobResponse},
    "background_agent_job.get" =>
      {BackgroundAgentJobBroker, :handle_get, :turn_read,
       FabricProto.BackgroundAgentJobGetRequest, FabricProto.BackgroundAgentJobResponse},
    "background_agent_job.list" =>
      {BackgroundAgentJobBroker, :handle_list, :turn_read,
       FabricProto.BackgroundAgentJobListRequest, FabricProto.BackgroundAgentJobListResponse},
    "background_agent_job.message.send" =>
      {BackgroundAgentJobBroker, :handle_message_send, :turn_write,
       FabricProto.BackgroundAgentJobMessageSendRequest,
       FabricProto.BackgroundAgentJobMessageSendResponse},
    "background_agent_job.message.result" =>
      {BackgroundAgentJobBroker, :handle_message_result, :turn_read,
       FabricProto.BackgroundAgentJobMessageResultRequest,
       FabricProto.BackgroundAgentJobMessageResultResponse},
    "background_agent_job.respawn" =>
      {BackgroundAgentJobBroker, :handle_respawn, :turn_write,
       FabricProto.BackgroundAgentJobRespawnRequest,
       FabricProto.BackgroundAgentJobRespawnResponse},
    "background_agent_job.stop" =>
      {BackgroundAgentJobBroker, :handle_stop, :turn_write,
       FabricProto.BackgroundAgentJobStopRequest, FabricProto.BackgroundAgentJobStopResponse},
    "background_agent_job.turn.upsert" =>
      {BackgroundAgentJobBroker, :handle_upsert_turn, :turn_write,
       FabricProto.BackgroundAgentJobTurnUpsertRequest,
       FabricProto.BackgroundAgentJobTurnUpsertResponse},
    "background_agent_job.turn_items.list" =>
      {BackgroundAgentJobBroker, :handle_turn_items_list, :turn_read,
       FabricProto.BackgroundAgentJobTurnItemsListRequest,
       FabricProto.BackgroundAgentJobTurnItemsListResponse},
    "background_agent_job.status.update" =>
      {BackgroundAgentJobBroker, :handle_update_status, :turn_write,
       FabricProto.BackgroundAgentJobStatusUpdateRequest, FabricProto.BackgroundAgentJobResponse},
    "observability.spans.export" =>
      {ObservabilityBroker, :handle_export, :worker_agent,
       FabricProto.ObservabilitySpansExportRequest, FabricProto.ObservabilitySpansExportResponse},
    "schedule.check_back_later.create" =>
      {ScheduleRPCBroker, :handle_check_back_later_create, :turn_write,
       FabricProto.ScheduleCheckBackLaterCreateRequest, FabricProto.JSONPassthroughResponse},
    "schedule.check_back_later.list" =>
      {ScheduleRPCBroker, :handle_check_back_later_list, :turn_read,
       FabricProto.ScheduleCheckBackLaterListRequest, FabricProto.JSONPassthroughResponse},
    "schedule.check_back_later.get" =>
      {ScheduleRPCBroker, :handle_check_back_later_get, :turn_read,
       FabricProto.ScheduleCheckBackLaterTargetRequest, FabricProto.JSONPassthroughResponse},
    "schedule.check_back_later.update" =>
      {ScheduleRPCBroker, :handle_check_back_later_update, :turn_write,
       FabricProto.ScheduleCheckBackLaterUpdateRequest, FabricProto.JSONPassthroughResponse},
    "schedule.check_back_later.cancel" =>
      {ScheduleRPCBroker, :handle_check_back_later_cancel, :turn_write,
       FabricProto.ScheduleCheckBackLaterTargetRequest, FabricProto.JSONPassthroughResponse},
    "schedule.cron.list" =>
      {ScheduleRPCBroker, :handle_cron_list, :turn_read, FabricProto.ScheduleCronListRequest,
       FabricProto.JSONPassthroughResponse},
    "schedule.cron.get" =>
      {ScheduleRPCBroker, :handle_cron_get, :turn_read, FabricProto.ScheduleCronTargetRequest,
       FabricProto.JSONPassthroughResponse},
    "schedule.cron.runs" =>
      {ScheduleRPCBroker, :handle_cron_runs, :turn_read, FabricProto.ScheduleCronRunsRequest,
       FabricProto.JSONPassthroughResponse},
    "schedule.cron.add" =>
      {ScheduleRPCBroker, :handle_cron_add, :turn_write, FabricProto.ScheduleCronAddRequest,
       FabricProto.JSONPassthroughResponse},
    "schedule.cron.update" =>
      {ScheduleRPCBroker, :handle_cron_update, :turn_write, FabricProto.ScheduleCronUpdateRequest,
       FabricProto.JSONPassthroughResponse},
    "schedule.cron.pause" =>
      {ScheduleRPCBroker, :handle_cron_pause, :turn_write, FabricProto.ScheduleCronTargetRequest,
       FabricProto.JSONPassthroughResponse},
    "schedule.cron.resume" =>
      {ScheduleRPCBroker, :handle_cron_resume, :turn_write, FabricProto.ScheduleCronTargetRequest,
       FabricProto.JSONPassthroughResponse},
    "schedule.cron.remove" =>
      {ScheduleRPCBroker, :handle_cron_remove, :turn_write, FabricProto.ScheduleCronTargetRequest,
       FabricProto.JSONPassthroughResponse},
    "schedule.cron.run" =>
      {ScheduleRPCBroker, :handle_cron_run, :turn_write, FabricProto.ScheduleCronRunRequest,
       FabricProto.JSONPassthroughResponse},
    "signal_channel.ambient_judgment.record" =>
      {SignalChannelBroker, :handle_ambient_judgment_record, :turn_write,
       FabricProto.AmbientJudgmentRecordRequest, FabricProto.JSONPassthroughResponse},
    "signal_channel.standing_orders.set" =>
      {SignalChannelBroker, :handle_standing_orders_set, :turn_write,
       FabricProto.SignalChannelStandingOrdersSetRequest, FabricProto.JSONPassthroughResponse},
    "webhook.endpoint.create" =>
      {WebhookRPCBroker, :handle_create, :turn_write, FabricProto.WebhookEndpointCreateRequest,
       FabricProto.JSONPassthroughResponse},
    "webhook.endpoint.list" =>
      {WebhookRPCBroker, :handle_list, :turn_read, FabricProto.WebhookEndpointListRequest,
       FabricProto.JSONPassthroughResponse},
    "webhook.endpoint.cancel" =>
      {WebhookRPCBroker, :handle_cancel, :turn_write, FabricProto.WebhookEndpointTargetRequest,
       FabricProto.JSONPassthroughResponse},
    "skills.installed.replace" =>
      {SkillRegistryBroker, :handle_replace, :turn_write,
       FabricProto.InstalledSkillReplaceRequest, FabricProto.InstalledSkillReplaceResponse},
    "skills.overlay.resolve" =>
      {SkillOverlayBroker, :handle_resolve, :turn_read, FabricProto.SkillOverlayResolveRequest,
       FabricProto.SkillOverlayResolveResponse},
    "worker_env.resolve" =>
      {WorkerEnvBroker, :handle_request, :worker_agent, FabricProto.WorkerEnvResolveRequest,
       FabricProto.WorkerEnvResolveResponse},
    "workflow.create" =>
      {WorkflowBroker, :handle_create, :turn_write, FabricProto.WorkflowCreateRequest,
       FabricProto.WorkflowCreateResponse},
    "workflow.get" =>
      {WorkflowBroker, :handle_get, :turn_read, FabricProto.WorkflowGetRequest,
       FabricProto.WorkflowGetResponse},
    "workflow.list" =>
      {WorkflowBroker, :handle_list, :turn_read, FabricProto.WorkflowListRequest,
       FabricProto.WorkflowListResponse},
    "workflow.cancel" =>
      {WorkflowBroker, :handle_cancel, :turn_write, FabricProto.WorkflowCancelRequest,
       FabricProto.WorkflowCancelResponse},
    "workflow.task.result.submit" =>
      {WorkflowBroker, :handle_task_result_submit, :turn_write,
       FabricProto.WorkflowTaskResultSubmitRequest, FabricProto.WorkflowTaskResultSubmitResponse},
    "workflow.task.sleep" =>
      {WorkflowBroker, :handle_task_sleep, :turn_write, FabricProto.WorkflowTaskSleepRequest,
       FabricProto.WorkflowTaskSleepResponse},
    "workflow.task.message.send" =>
      {WorkflowBroker, :handle_task_message_send, :turn_write,
       FabricProto.WorkflowTaskMessageSendRequest, FabricProto.WorkflowTaskMessageSendResponse}
  }

  @doc false
  @spec operations() :: %{String.t() => {module(), atom(), scope(), module(), module()}}
  def operations, do: @rpc_operations

  @spec handle_request(FabricProto.RPCRequest.t(), String.t()) ::
          {:ok, FabricProto.Envelope.t()} | {:error, term()}
  def handle_request(%FabricProto.RPCRequest{} = request, route) when is_binary(route) do
    request_id = presence(request.request_id) || "rpc-#{Ecto.UUID.generate()}"
    ctx = %{route: route, request_id: request_id}

    case dispatch_method_safely(request, ctx) do
      {:ok, %_{} = response_struct} ->
        {:ok, rpc_response_envelope(request_id, encode_payload(response_struct))}

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
      {:ok, response} ->
        normalize_handler_response(request, response, ctx)

      {:error, error_payload} = result when is_map(error_payload) ->
        result

      _unexpected ->
        invalid_handler_result(request, ctx)
    end
  rescue
    exception ->
      failure_id = Ecto.UUID.generate()

      log_handler_failure(
        request.method,
        ctx.route,
        failure_id,
        :error,
        exception,
        __STACKTRACE__
      )

      {:error, handler_failure_payload(ctx.request_id, request.method, failure_id)}
  catch
    kind, reason ->
      failure_id = Ecto.UUID.generate()
      log_handler_failure(request.method, ctx.route, failure_id, kind, reason, __STACKTRACE__)
      {:error, handler_failure_payload(ctx.request_id, request.method, failure_id)}
  end

  defp normalize_handler_response(request, %_{} = response_struct, ctx) do
    case response_module(request.method) do
      {:ok, response_mod} when response_struct.__struct__ == response_mod ->
        {:ok, response_struct}

      _mismatch ->
        invalid_handler_result(request, ctx)
    end
  end

  defp normalize_handler_response(request, response_payload, ctx) when is_map(response_payload) do
    case response_module(request.method) do
      {:ok, FabricProto.JSONPassthroughResponse} ->
        {:ok,
         %FabricProto.JSONPassthroughResponse{
           body_json: Torque.encode!(response_payload)
         }}

      _mismatch ->
        invalid_handler_result(request, ctx)
    end
  end

  defp normalize_handler_response(request, _unexpected, ctx),
    do: invalid_handler_result(request, ctx)

  defp response_module(method) do
    case Map.fetch(@rpc_operations, method) do
      {:ok, {_module, _function, _scope, _request_mod, response_mod}} -> {:ok, response_mod}
      :error -> :error
    end
  end

  defp invalid_handler_result(request, ctx) do
    failure_id = Ecto.UUID.generate()
    log_invalid_handler_result(request.method, ctx.route, failure_id)
    {:error, handler_failure_payload(ctx.request_id, request.method, failure_id)}
  end

  defp dispatch_method(request, ctx) do
    case Map.fetch(@rpc_operations, request.method) do
      {:ok, {module, function, :worker_agent, request_mod, _response_mod}} ->
        with {:ok, payload} <- decode_payload(request_mod, request.payload, ctx) do
          apply(module, function, [presence(request.agent_uid), payload, ctx])
        end

      {:ok, {module, function, :turn_complete, request_mod, _response_mod}} ->
        with {:ok, turn_ref} <- request_turn_ref(request, ctx),
             :ok <- authorize_turn_completion(turn_ref, ctx),
             {:ok, payload} <- decode_payload(request_mod, request.payload, ctx) do
          apply(module, function, [turn_ref, payload, ctx])
        end

      {:ok, {module, function, scope, request_mod, _response_mod}} ->
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

  defp authorize_turn_completion(turn_ref, ctx) do
    case WorkerRouteAuth.authorize_turn_completion_route(turn_ref, ctx.route) do
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
      message_id: "rpc-response-#{Ecto.UUID.generate()}",
      correlation_id: request_id,
      sent_at_unix_ms: System.system_time(:millisecond),
      body:
        {:rpc_response,
         %FabricProto.RPCResponse{
           request_id: request_id,
           payload: payload
         }}
    }
  end

  defp rpc_error_envelope(request_id, error_payload) do
    details =
      error_payload
      |> RPCWire.map_value("details_json", %{})
      |> RPCWire.stringify_keys()
      |> Map.put_new("retryable", false)

    %FabricProto.Envelope{
      message_id: "rpc-error-#{Ecto.UUID.generate()}",
      correlation_id: request_id,
      sent_at_unix_ms: System.system_time(:millisecond),
      body:
        {:rpc_error,
         %FabricProto.RPCError{
           request_id: RPCWire.text(error_payload, "request_id") || request_id,
           code: RPCWire.text(error_payload, "code") || "rpc_request_failed",
           message: RPCWire.text(error_payload, "message") || "RPC request failed",
           details_json: Torque.encode!(details)
         }}
    }
  end

  defp auth_error_payload(ctx, reason) do
    RPCWire.error_payload(ctx.request_id, reason,
      fallback_code: "rpc_request_failed",
      details_json: %{"reason" => inspect(reason)}
    )
  end

  defp handler_failure_payload(request_id, method, failure_id) do
    %{
      "request_id" => request_id,
      "code" => "rpc_handler_failed",
      "message" => "RPC handler failed",
      "details_json" => %{
        "failure_id" => failure_id,
        "method" => method,
        "retryable" => retryable_handler_failure?(method)
      }
    }
  end

  # Read operations are side-effect free. Turn checkpoint upsert is the one
  # retryable write: its revision and item keys make the same request
  # idempotent whether the failed handler committed or rolled back.
  @doc false
  @spec retryable_handler_failure?(String.t()) :: boolean()
  def retryable_handler_failure?(method) do
    case Map.get(@rpc_operations, method) do
      {_module, _function, :turn_read, _request_mod, _response_mod} -> true
      _operation -> method == "background_agent_job.turn.upsert"
    end
  end

  defp log_handler_failure(method, route, failure_id, kind, reason, stacktrace) do
    Logging.error(
      "runtime_fabric.rpc_handler_failed",
      "runtime fabric rpc handler failed",
      %{
        failure_id: failure_id,
        method: method,
        route: route,
        reason: Exception.format(kind, reason, stacktrace)
      }
    )
  end

  defp log_invalid_handler_result(method, route, failure_id) do
    Logging.error(
      "runtime_fabric.rpc_handler_invalid_result",
      "runtime fabric rpc handler returned an invalid result",
      %{
        failure_id: failure_id,
        method: method,
        route: route
      }
    )
  end
end
