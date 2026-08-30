defmodule Ankole.SignalsGateway.ActorRuntime.WorkflowBroker do
  @moduledoc """
  RuntimeFabric RPC boundary for durable Workflow runs and task results.
  """

  alias Ankole.BackgroundAgentJobs
  alias Ankole.Repo
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.Workflow
  alias Ankole.Workflow.Schemas.Run

  require Ankole.BackgroundAgentJobs
  require Ankole.Workflow

  @max_result_offset 2_147_483_646
  @max_args_json_bytes 64 * 1_024
  @max_value_json_bytes 24 * 1_024

  @spec handle_create(TurnRef.t(), FabricProto.WorkflowCreateRequest.t(), map()) ::
          {:ok, FabricProto.WorkflowCreateResponse.t()} | {:error, map()}
  def handle_create(%TurnRef{} = turn_ref, %FabricProto.WorkflowCreateRequest{} = request, ctx) do
    with :ok <- require_owner_turn(turn_ref),
         {:ok, actor_event} <- fetch_actor_event_for_turn(turn_ref),
         {:ok, args} <- decode_args(request.args_json),
         attrs <-
           %{
             "agent_uid" => turn_ref.agent_uid,
             "owner_session_id" => turn_ref.session_id,
             "source_actor_event_id" => turn_ref.actor_event_id,
             "source_tool_call_id" => request.source_tool_call_id,
             "reply_route" => reply_route(actor_event),
             "title" => request.title,
             "script" => request.script,
             "args" => args
           }
           |> put_optional("concurrency", request.concurrency)
           |> put_optional("max_agent_calls", request.max_agent_calls)
           |> put_present("model_profile", request.model_profile),
         {:ok, %{run: %Run{} = run}} <- Workflow.create_with_dispatch(attrs) do
      {:ok,
       %FabricProto.WorkflowCreateResponse{
         run_id: Integer.to_string(run.id),
         status: run.status
       }}
    else
      {:error, reason} -> error(ctx.request_id, turn_ref.agent_uid, reason)
    end
  end

  @spec handle_get(TurnRef.t(), FabricProto.WorkflowGetRequest.t(), map()) ::
          {:ok, FabricProto.WorkflowGetResponse.t()} | {:error, map()}
  def handle_get(%TurnRef{} = turn_ref, %FabricProto.WorkflowGetRequest{} = request, ctx) do
    with {:ok, run_id} <- request_run_id(request.run_id),
         {:ok, offset} <- request_result_offset(request.result_offset),
         {:ok, result} <- Workflow.get(run_id, turn_ref.agent_uid, result_options(offset)) do
      run = result.run

      {:ok,
       %FabricProto.WorkflowGetResponse{
         run_id: Integer.to_string(run.id),
         title: run.title,
         status: run.status,
         counts_json: Torque.encode!(result.counts),
         failure_summaries_json: Torque.encode!(result.failure_summaries),
         live_tasks_json: Torque.encode!(result.live_tasks),
         error_json: Torque.encode!(run.error || %{}),
         result_output_text: result.result_output_text,
         result_output_total_bytes: optional_integer(result.result_output_total_bytes)
       }}
    else
      {:error, reason} -> error(ctx.request_id, turn_ref.agent_uid, reason)
    end
  end

  @spec handle_list(TurnRef.t(), FabricProto.WorkflowListRequest.t(), map()) ::
          {:ok, FabricProto.WorkflowListResponse.t()} | {:error, map()}
  def handle_list(%TurnRef{} = turn_ref, %FabricProto.WorkflowListRequest{} = request, ctx) do
    with {:ok, result} <-
           Workflow.list(turn_ref.agent_uid,
             status: presence(request.status),
             cursor: presence(request.cursor)
           ) do
      {:ok,
       %FabricProto.WorkflowListResponse{
         runs_json: Torque.encode!(result.runs),
         next_cursor: result.next_cursor || ""
       }}
    else
      {:error, reason} -> error(ctx.request_id, turn_ref.agent_uid, reason)
    end
  end

  @spec handle_cancel(TurnRef.t(), FabricProto.WorkflowCancelRequest.t(), map()) ::
          {:ok, FabricProto.WorkflowCancelResponse.t()} | {:error, map()}
  def handle_cancel(%TurnRef{} = turn_ref, %FabricProto.WorkflowCancelRequest{} = request, ctx) do
    with {:ok, run_id} <- request_run_id(request.run_id),
         {:ok, %{run: %Run{} = run}} <- Workflow.cancel(run_id, turn_ref.agent_uid) do
      {:ok,
       %FabricProto.WorkflowCancelResponse{
         run_id: Integer.to_string(run.id),
         status: run.status
       }}
    else
      {:error, reason} -> error(ctx.request_id, turn_ref.agent_uid, reason)
    end
  end

  @spec handle_task_result_submit(
          TurnRef.t(),
          FabricProto.WorkflowTaskResultSubmitRequest.t(),
          map()
        ) :: {:ok, FabricProto.WorkflowTaskResultSubmitResponse.t()} | {:error, map()}
  def handle_task_result_submit(
        %TurnRef{} = turn_ref,
        %FabricProto.WorkflowTaskResultSubmitRequest{} = request,
        ctx
      ) do
    with {:ok, call_id} <- request_call_id(request.call_id),
         {:ok, outcome} <- request_outcome(request),
         {:ok, result} <-
           Workflow.submit_result(
             call_id,
             turn_ref.agent_uid,
             turn_ref.session_id,
             outcome
           ) do
      {:ok,
       %FabricProto.WorkflowTaskResultSubmitResponse{
         accepted: result.accepted,
         task_status: result.call.status
       }}
    else
      {:error, reason} -> error(ctx.request_id, turn_ref.agent_uid, reason)
    end
  end

  @spec handle_task_sleep(TurnRef.t(), FabricProto.WorkflowTaskSleepRequest.t(), map()) ::
          {:ok, FabricProto.WorkflowTaskSleepResponse.t()} | {:error, map()}
  def handle_task_sleep(
        %TurnRef{} = turn_ref,
        %FabricProto.WorkflowTaskSleepRequest{} = request,
        ctx
      ) do
    with {:ok, call_id} <- request_call_id(request.call_id),
         {:ok, result} <-
           Workflow.sleep_task(call_id, turn_ref.agent_uid, turn_ref.session_id, %{
             wake_after_ms: request.wake_after_ms,
             note: request.note,
             attention: request.attention
           }) do
      {:ok,
       %FabricProto.WorkflowTaskSleepResponse{
         task_status: result.call.status,
         wake_count: result.call.wake_count
       }}
    else
      {:error, reason} -> error(ctx.request_id, turn_ref.agent_uid, reason)
    end
  end

  @spec handle_task_message_send(
          TurnRef.t(),
          FabricProto.WorkflowTaskMessageSendRequest.t(),
          map()
        ) :: {:ok, FabricProto.WorkflowTaskMessageSendResponse.t()} | {:error, map()}
  def handle_task_message_send(
        %TurnRef{} = turn_ref,
        %FabricProto.WorkflowTaskMessageSendRequest{} = request,
        ctx
      ) do
    with :ok <- require_owner_turn(turn_ref),
         {:ok, run_id} <- request_run_id(request.run_id),
         {:ok, result} <-
           Workflow.send_task_message(
             run_id,
             request.call_seq,
             turn_ref.agent_uid,
             request.message,
             request.source_tool_call_id
           ) do
      {:ok,
       %FabricProto.WorkflowTaskMessageSendResponse{
         run_id: Integer.to_string(run_id),
         call_seq: request.call_seq,
         task_status: result.call.status
       }}
    else
      {:error, reason} -> error(ctx.request_id, turn_ref.agent_uid, reason)
    end
  end

  defp request_outcome(%FabricProto.WorkflowTaskResultSubmitRequest{ok: true} = request) do
    if byte_size(request.value_json) > @max_value_json_bytes do
      {:error, :workflow_result_too_large}
    else
      case Torque.decode(request.value_json) do
        {:ok, value} -> {:ok, %{"ok" => true, "value" => value}}
        {:error, reason} -> {:error, {:invalid_workflow_result_json, reason}}
      end
    end
  end

  defp request_outcome(%FabricProto.WorkflowTaskResultSubmitRequest{} = request) do
    {:ok,
     %{
       "ok" => false,
       "code" => request.code,
       "summary" => request.summary,
       "retryable" => request.retryable
     }}
  end

  defp decode_args(bytes) when bytes in [nil, ""], do: {:ok, %{}}

  defp decode_args(bytes) when is_binary(bytes) and byte_size(bytes) > @max_args_json_bytes,
    do: {:error, :workflow_args_too_large}

  defp decode_args(bytes) when is_binary(bytes) do
    case Torque.decode(bytes) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, :invalid_workflow_args}
      {:error, reason} -> {:error, {:invalid_workflow_args_json, reason}}
    end
  end

  defp request_run_id(value) do
    case Workflow.parse_run_id(value) do
      {:ok, run_id} -> {:ok, run_id}
      :error -> {:error, :invalid_workflow_run_id}
    end
  end

  defp request_call_id(value) do
    case Workflow.parse_call_id(value) do
      {:ok, call_id} -> {:ok, call_id}
      :error -> {:error, :invalid_workflow_call_id}
    end
  end

  defp request_result_offset(""), do: {:ok, nil}

  defp request_result_offset(value) when is_binary(value) do
    case Integer.parse(value) do
      {offset, ""} when offset >= 0 and offset <= @max_result_offset -> {:ok, offset}
      _value -> {:error, :invalid_workflow_result_offset}
    end
  end

  defp result_options(nil), do: []
  defp result_options(offset), do: [result_offset: offset]

  defp require_owner_turn(%TurnRef{session_id: session_id})
       when BackgroundAgentJobs.is_job_session_id(session_id),
       do: {:error, :workflow_owner_turn_required}

  defp require_owner_turn(%TurnRef{session_id: session_id})
       when Workflow.is_workflow_task_session_id(session_id),
       do: {:error, :workflow_owner_turn_required}

  defp require_owner_turn(%TurnRef{}), do: :ok

  defp fetch_actor_event_for_turn(turn_ref) do
    case Repo.get(ActorEvent, turn_ref.actor_event_id) do
      %ActorEvent{agent_uid: agent_uid, session_id: session_id} = event
      when agent_uid == turn_ref.agent_uid and session_id == turn_ref.session_id ->
        {:ok, event}

      _event ->
        {:error, :actor_event_not_found}
    end
  end

  defp reply_route(actor_event) do
    route =
      %{
        "binding_name" => actor_event.binding_name,
        "signal_channel_id" => actor_event.signal_channel_id,
        "provider_thread_id" => actor_event.provider_thread_id,
        "source_entry_id" => actor_event.source_entry_id
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    case ActorEvent.scheduled_delivery_snapshot(actor_event) do
      %{} = delivery -> Map.put(route, "delivery", delivery)
      _missing -> route
    end
  end

  defp error(request_id, agent_uid, reason) do
    {:error,
     RPCWire.error_payload(request_id, reason,
       fallback_code: "workflow_failed",
       changeset_code: "invalid_workflow",
       message_style: :tuple_inspect,
       details_json: %{"agent_uid" => agent_uid}
     )}
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp optional_integer(nil), do: ""
  defp optional_integer(value) when is_integer(value), do: Integer.to_string(value)
end
