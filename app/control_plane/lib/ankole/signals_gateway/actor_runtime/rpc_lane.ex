defmodule Ankole.SignalsGateway.ActorRuntime.RPCLane do
  @moduledoc """
  Dispatches RuntimeFabric RPC requests on the control-plane side.

  The Bun operation table owns method facts. The generated rpc_methods.json
  supplies authorization scope and message modules at compile time. The local
  table maps methods to broker functions. Turn authorization precedes payload
  decoding, and worker_agent identity comes from the authenticated connection.

  Add messages and generate proto, add a Bun row and generate the contract,
  then add the broker mapping and its function clause. Compilation rejects
  missing rows, unknown scope and missing messages. Tests check broker exports.

  This module is the single control-plane codec boundary for RPC payloads.
  Brokers receive the decoded request struct plus a `ctx` map carrying the
  connection and frame facts (`route`, `worker_id`, `request_id`). A response
  struct must match the row's
  response module. A plain map is valid only for a row whose response module is
  `JSONPassthroughResponse`; this module wraps that map for the model. Error
  payload maps become `rpc_error` frames.
  """

  alias Ankole.AutomationJobs.RPCBroker, as: AutomationJobRPCBroker
  alias Ankole.Files.RPCBroker, as: FilesRPCBroker
  alias Ankole.Logging
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.JobAbort
  alias Ankole.SignalsGateway.ActorRuntime.AIGatewayAPIKeyBroker
  alias Ankole.SignalsGateway.ActorRuntime.BackgroundAgentJobBroker
  alias Ankole.SignalsGateway.ActorRuntime.ObservabilityBroker
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire
  alias Ankole.SignalsGateway.ActorRuntime.ReadToolBroker
  alias Ankole.Conversations.{RunRef, JobTurnRef}
  alias Ankole.SignalsGateway.ActorRuntime.WorkerEnvBroker
  alias Ankole.SignalsGateway.ActorRuntime.WorkerRouteAuth
  alias Ankole.SignalsGateway.Webhooks.RPCBroker, as: WebhookRPCBroker

  @typedoc "Authorization scope of one operation; turn scopes carry the WorkerRouteAuth effect."
  @type scope :: :worker_agent | :turn_read | :turn_write | :turn_complete

  @typedoc """
  Connection and frame facts handed to every broker beside the decoded
  request. `worker_id` is the Agent of the connection.
  """
  @type ctx :: %{route: String.t(), worker_id: String.t(), request_id: String.t()}

  @contract_path Path.expand(
                   "../../../../../kernel/proto/ankole/runtime_fabric/v1/rpc_methods.json",
                   __DIR__
                 )
  @external_resource @contract_path

  @brokers %{
    "ai_gateway.api_key_for.create_or_find_by_agent" => {AIGatewayAPIKeyBroker, :handle_request},
    "actor_turn.abort" => {JobAbort, :handle_abort},
    "automation_job.create" => {AutomationJobRPCBroker, :handle_create},
    "automation_job.list" => {AutomationJobRPCBroker, :handle_list},
    "automation_job.show" => {AutomationJobRPCBroker, :handle_show},
    "automation_job.cancel" => {AutomationJobRPCBroker, :handle_cancel},
    "automation_job.emit" => {AutomationJobRPCBroker, :handle_emit},
    "background_agent_job.get" => {BackgroundAgentJobBroker, :handle_get},
    "background_agent_job.turn.upsert" => {BackgroundAgentJobBroker, :handle_upsert_turn},
    "background_agent_job.turn_items.list" => {BackgroundAgentJobBroker, :handle_turn_items_list},
    "background_agent_job.status.update" => {BackgroundAgentJobBroker, :handle_update_status},
    "observability.spans.export" => {ObservabilityBroker, :handle_export},
    "webhook.endpoint.create" => {WebhookRPCBroker, :handle_create},
    "webhook.endpoint.list" => {WebhookRPCBroker, :handle_list},
    "webhook.endpoint.cancel" => {WebhookRPCBroker, :handle_cancel},
    "tools.read" => {ReadToolBroker, :handle_read},
    "files.list" => {FilesRPCBroker, :handle_list},
    "files.get" => {FilesRPCBroker, :handle_get},
    "files.commit" => {FilesRPCBroker, :handle_commit},
    "worker_env.resolve" => {WorkerEnvBroker, :handle_request}
  }

  @rpc_operations (for %{"method" => method} = entry <- Torque.decode!(File.read!(@contract_path)),
                       entry["owner"] != "worker",
                       into: %{} do
                     {module, function} =
                       Map.get(@brokers, method) ||
                         raise(CompileError, description: "RPC method #{method} has no broker")

                     scope =
                       case {entry["scope"], entry["effect"]} do
                         {"worker_agent", nil} ->
                           :worker_agent

                         {"turn", "read"} ->
                           :turn_read

                         {"turn", "write"} ->
                           :turn_write

                         {"turn", "complete"} ->
                           :turn_complete

                         other ->
                           raise(CompileError,
                             description: "RPC method #{method} has scope #{inspect(other)}"
                           )
                       end

                     [request_mod, response_mod] =
                       for type <- [entry["request_type"], entry["response_type"]] do
                         Code.ensure_compiled!(
                           Module.concat(
                             Ankole.RuntimeFabric.V1,
                             String.replace_prefix(type, "ankole.runtime_fabric.v1.", "")
                           )
                         )
                       end

                     {method, {module, function, scope, request_mod, response_mod}}
                   end)

  extra = Map.keys(@brokers) -- Map.keys(@rpc_operations)

  if extra != [],
    do: raise(CompileError, description: "brokers without a contract row: #{inspect(extra)}")

  @doc false
  @spec operations() :: %{String.t() => {module(), atom(), scope(), module(), module()}}
  def operations, do: @rpc_operations

  @spec handle_request(FabricProto.RPCRequest.t(), %{
          transport_route: String.t(),
          worker_id: String.t()
        }) ::
          {:ok, FabricProto.Envelope.t()} | {:error, term()}
  def handle_request(
        %FabricProto.RPCRequest{} = request,
        %{transport_route: route, worker_id: worker_id}
      )
      when is_binary(route) and is_binary(worker_id) do
    request_id = presence(request.request_id) || "rpc-#{Ecto.UUID.generate()}"
    ctx = %{route: route, worker_id: worker_id, request_id: request_id}

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

  # A defect or unexpected database failure in one semantic method must fail
  # that RPC, not end the Worker Channel that carries it.
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
      # The Agent of a `worker_agent` RPC is the Agent of the calling Worker:
      # its connection proved the credential of that Agent's generation.
      {:ok, {module, function, :worker_agent, request_mod, _response_mod}} ->
        with {:ok, payload} <- decode_payload(request_mod, request.payload, ctx) do
          apply(module, function, [ctx.worker_id, payload, ctx])
        end

      {:ok, {module, function, :turn_complete, request_mod, _response_mod}} ->
        with {:ok, turn_ref} <- request_turn_ref(request, ctx),
             :ok <- require_job_ref(turn_ref, ctx),
             :ok <- authorize_turn_completion(turn_ref, ctx),
             {:ok, payload} <- decode_payload(request_mod, request.payload, ctx) do
          apply(module, function, [turn_ref, payload, ctx])
        end

      {:ok, {module, function, scope, request_mod, _response_mod}} ->
        with {:ok, turn_ref} <- request_turn_ref(request, ctx),
             :ok <- authorize_turn(turn_ref, ctx, scope_effect(scope)),
             :ok <- require_broker_ref(module, turn_ref, ctx),
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

  defp require_job_ref(%JobTurnRef{}, _ctx), do: :ok
  defp require_job_ref(_, ctx), do: {:error, auth_error_payload(ctx, :invalid_job_turn_ref)}

  defp require_broker_ref(BackgroundAgentJobBroker, ref, ctx), do: require_job_ref(ref, ctx)
  defp require_broker_ref(_broker, _ref, _ctx), do: :ok

  defp scope_effect(:turn_read), do: :read
  defp scope_effect(:turn_write), do: :write

  defp request_turn_ref(request, ctx) do
    result =
      case {request.run, request.job_turn} do
        {%FabricProto.RunRef{} = ref, nil} -> RunRef.from_proto(ref, ctx.worker_id)
        {nil, %FabricProto.JobTurnRef{} = ref} -> JobTurnRef.from_proto(ref, ctx.worker_id)
        _ -> {:error, :invalid_rpc_ref}
      end

    case result do
      {:ok, turn_ref} -> {:ok, turn_ref}
      {:error, reason} -> {:error, auth_error_payload(ctx, reason)}
    end
  end

  defp authorize_turn(turn_ref, ctx, effect) do
    case WorkerRouteAuth.authorize_turn(turn_ref, ctx.worker_id, effect) do
      :ok -> :ok
      {:error, reason} -> {:error, auth_error_payload(ctx, reason)}
    end
  end

  defp authorize_turn_completion(turn_ref, ctx) do
    case WorkerRouteAuth.authorize_turn(turn_ref, ctx.worker_id, :terminal) do
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

    %FabricProto.Envelope{
      message_id: "rpc-error-#{Ecto.UUID.generate()}",
      body:
        {:rpc_error,
         %FabricProto.RPCError{
           request_id: RPCWire.text(error_payload, "request_id") || request_id,
           code: RPCWire.text(error_payload, "code") || "rpc_request_failed",
           message: RPCWire.text(error_payload, "message") || "RPC request failed",
           retryable: error_payload["retryable"] == true,
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
      "retryable" => retryable_handler_failure?(method),
      "details_json" => %{
        "failure_id" => failure_id,
        "method" => method
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
