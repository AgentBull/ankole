defmodule Ankole.Schedule.RPCBroker do
  @moduledoc """
  RuntimeFabric RPC entry point for worker-originated schedule requests.

  One public function per operation, dispatched by `Ankole.SignalsGateway.ActorRuntime.RPCLane`
  after turn authorization.
  """

  alias Ankole.Repo
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.Schedule
  alias Ankole.Schedule.Delivery
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.Common
  alias Ankole.SignalsGateway.ActorRuntime.ReplyRoute
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SignalsGateway.AIGatewayLink

  @spec handle_check_back_later_create(
          TurnRef.t(),
          FabricProto.ScheduleCheckBackLaterCreateRequest.t(),
          map()
        ) ::
          {:ok, map()} | {:error, map()}
  def handle_check_back_later_create(%TurnRef{} = turn_ref, request, ctx) do
    respond(ctx, fn ->
      reply_route = Common.decode_json_bytes(request.reply_route_json)

      with {:ok, source} <- ReplyRoute.validate(turn_ref, reply_route),
           {:ok, attrs} <- checkback_attrs(request, turn_ref, source, ctx, reply_route),
           {:ok, %{status: status, scheduled_event: event}} <-
             Schedule.create_check_back_later(attrs) do
        {:ok,
         %{
           "status" => rpc_status(status),
           "due_at" => DateTime.to_iso8601(event.due_at),
           "timezone" => event.timezone,
           "quiet_success" => checkback_quiet_success(event)
         }}
      end
    end)
  end

  @spec handle_check_back_later_list(
          TurnRef.t(),
          FabricProto.ScheduleCheckBackLaterListRequest.t(),
          map()
        ) ::
          {:ok, map()} | {:error, map()}
  def handle_check_back_later_list(%TurnRef{} = turn_ref, request, ctx) do
    respond(ctx, fn ->
      {:ok,
       %{
         "status" => "ok",
         "checkbacks" =>
           turn_ref.agent_uid
           |> Schedule.list_pending_checkbacks(
             turn_ref.session_id,
             list_limit(request.limit, 10)
           )
           |> Enum.map(&Schedule.event_model_projection/1)
       }}
    end)
  end

  @spec handle_check_back_later_get(
          TurnRef.t(),
          FabricProto.ScheduleCheckBackLaterTargetRequest.t(),
          map()
        ) ::
          {:ok, map()} | {:error, map()}
  def handle_check_back_later_get(%TurnRef{} = turn_ref, request, ctx) do
    respond(ctx, fn ->
      with {:ok, event} <- checkback_from_turn(request.scheduled_event_id, turn_ref) do
        {:ok, %{"status" => "ok", "checkback" => Schedule.event_model_projection(event)}}
      end
    end)
  end

  @spec handle_check_back_later_update(
          TurnRef.t(),
          FabricProto.ScheduleCheckBackLaterUpdateRequest.t(),
          map()
        ) ::
          {:ok, map()} | {:error, map()}
  def handle_check_back_later_update(%TurnRef{} = turn_ref, request, ctx) do
    respond(ctx, fn ->
      reply_route = Common.decode_json_bytes(request.reply_route_json)

      with {:ok, event} <- checkback_from_turn(request.scheduled_event_id, turn_ref),
           {:ok, source} <- ReplyRoute.validate(turn_ref, reply_route),
           {:ok, attrs} <- checkback_update_attrs(request, turn_ref, source, ctx, reply_route),
           {:ok, %{status: status, scheduled_event: updated}} <-
             Schedule.update_checkback(event.id, attrs) do
        {:ok,
         %{
           "status" => checkback_update_status(status),
           "checkback" => Schedule.event_model_projection(updated)
         }}
      end
    end)
  end

  @spec handle_check_back_later_cancel(
          TurnRef.t(),
          FabricProto.ScheduleCheckBackLaterTargetRequest.t(),
          map()
        ) ::
          {:ok, map()} | {:error, map()}
  def handle_check_back_later_cancel(%TurnRef{} = turn_ref, request, ctx) do
    respond(ctx, fn ->
      with {:ok, event} <- checkback_from_turn(request.scheduled_event_id, turn_ref),
           {:ok, cancelled} <- Schedule.cancel_checkback(event.id) do
        {:ok,
         %{
           "status" => "cancelled",
           "checkback" => Schedule.event_model_projection(cancelled)
         }}
      end
    end)
  end

  @spec handle_cron_list(TurnRef.t(), FabricProto.ScheduleCronListRequest.t(), map()) ::
          {:ok, map()} | {:error, map()}
  def handle_cron_list(%TurnRef{} = turn_ref, _request, ctx) do
    respond(ctx, fn ->
      {:ok,
       %{
         "status" => "ok",
         "schedules" =>
           turn_ref.agent_uid
           |> Schedule.list_cron_schedules(turn_ref.session_id)
           |> Enum.map(&Schedule.cron_model_projection/1)
       }}
    end)
  end

  @spec handle_cron_get(TurnRef.t(), FabricProto.ScheduleCronTargetRequest.t(), map()) ::
          {:ok, map()} | {:error, map()}
  def handle_cron_get(%TurnRef{} = turn_ref, request, ctx) do
    respond(ctx, fn ->
      with {:ok, schedule} <- cron_schedule_from_turn(request.name, turn_ref) do
        {:ok, %{"status" => "ok", "schedule" => Schedule.cron_model_projection(schedule)}}
      end
    end)
  end

  @spec handle_cron_runs(TurnRef.t(), FabricProto.ScheduleCronRunsRequest.t(), map()) ::
          {:ok, map()} | {:error, map()}
  def handle_cron_runs(%TurnRef{} = turn_ref, request, ctx) do
    respond(ctx, fn ->
      with {:ok, schedule} <- cron_schedule_from_turn(request.name, turn_ref) do
        {:ok,
         %{
           "status" => "ok",
           "runs" =>
             schedule.id
             |> Schedule.list_cron_runs(list_limit(request.limit, 25))
             |> Enum.map(&Schedule.event_model_projection/1)
         }}
      end
    end)
  end

  @spec handle_cron_add(TurnRef.t(), FabricProto.ScheduleCronAddRequest.t(), map()) ::
          {:ok, map()} | {:error, map()}
  def handle_cron_add(%TurnRef{} = turn_ref, request, ctx) do
    respond(ctx, fn ->
      with :ok <- reject_cron_origin_broad_mutation(turn_ref),
           {:ok, attrs} <- cron_attrs(request, turn_ref),
           created_by <- turn_created_by(turn_ref),
           {:ok, %{status: status, cron_schedule: schedule}} <-
             Schedule.create_cron_schedule(attrs, created_by: created_by) do
        {:ok,
         %{
           "status" => cron_create_status(status),
           "schedule" => Schedule.cron_model_projection(schedule)
         }}
      end
    end)
  end

  @spec handle_cron_update(TurnRef.t(), FabricProto.ScheduleCronUpdateRequest.t(), map()) ::
          {:ok, map()} | {:error, map()}
  def handle_cron_update(%TurnRef{} = turn_ref, request, ctx) do
    respond(ctx, fn ->
      with :ok <- reject_cron_origin_broad_mutation(turn_ref),
           {:ok, schedule} <- cron_schedule_from_turn(request.name, turn_ref),
           updates <- Common.decode_json_bytes(request.updates_json) || %{},
           :ok <- validate_cron_update_delivery_route(turn_ref, schedule.binding_name, updates),
           {:ok, updated} <- Schedule.update_cron_schedule(schedule.id, updates) do
        {:ok, %{"status" => "updated", "schedule" => Schedule.cron_model_projection(updated)}}
      end
    end)
  end

  @spec handle_cron_pause(TurnRef.t(), FabricProto.ScheduleCronTargetRequest.t(), map()) ::
          {:ok, map()} | {:error, map()}
  def handle_cron_pause(%TurnRef{} = turn_ref, request, ctx) do
    respond(ctx, fn ->
      mutate_cron_from_turn(request, turn_ref, "paused", &Schedule.pause_cron_schedule/1)
    end)
  end

  @spec handle_cron_resume(TurnRef.t(), FabricProto.ScheduleCronTargetRequest.t(), map()) ::
          {:ok, map()} | {:error, map()}
  def handle_cron_resume(%TurnRef{} = turn_ref, request, ctx) do
    respond(ctx, fn ->
      mutate_cron_from_turn(request, turn_ref, "resumed", &Schedule.resume_cron_schedule/1)
    end)
  end

  @spec handle_cron_remove(TurnRef.t(), FabricProto.ScheduleCronTargetRequest.t(), map()) ::
          {:ok, map()} | {:error, map()}
  def handle_cron_remove(%TurnRef{} = turn_ref, request, ctx) do
    respond(ctx, fn ->
      mutate_cron_from_turn(request, turn_ref, "removed", &Schedule.remove_cron_schedule/1)
    end)
  end

  @spec handle_cron_run(TurnRef.t(), FabricProto.ScheduleCronRunRequest.t(), map()) ::
          {:ok, map()} | {:error, map()}
  def handle_cron_run(%TurnRef{} = turn_ref, request, ctx) do
    respond(ctx, fn ->
      with :ok <- reject_cron_origin_broad_mutation(turn_ref),
           {:ok, schedule} <- cron_schedule_from_turn(request.name, turn_ref),
           {:ok, %{status: status, scheduled_event: event}} <-
             Schedule.run_cron_schedule(schedule.id, tool_call_id: request.tool_call_id) do
        {:ok,
         %{
           "status" => rpc_status(status),
           "scheduled_event" => Schedule.event_model_projection(event)
         }}
      end
    end)
  end

  defp respond(ctx, fun) do
    case fun.() do
      {:ok, payload} -> {:ok, payload}
      {:error, reason} -> {:error, error_payload(ctx.request_id, reason)}
    end
  end

  defp cron_schedule_from_turn(name, %TurnRef{} = turn_ref) do
    with {:ok, schedule} <- cron_schedule_from_name_or_origin(name, turn_ref),
         :ok <- cron_belongs_to_turn(schedule, turn_ref) do
      {:ok, schedule}
    end
  end

  defp cron_schedule_from_name_or_origin(name, %TurnRef{} = turn_ref) do
    case presence(name) do
      name when is_binary(name) ->
        Schedule.get_cron_schedule_by_name(turn_ref.agent_uid, turn_ref.session_id, name)

      nil ->
        case cron_origin_schedule_id(turn_ref) do
          cron_schedule_id when is_binary(cron_schedule_id) ->
            Schedule.get_cron_schedule(cron_schedule_id)

          _cron_schedule_id ->
            {:error, {:missing_text, :name}}
        end
    end
  end

  defp checkback_from_turn(scheduled_event_id, %TurnRef{} = turn_ref) do
    with {:ok, scheduled_event_id} <- safe_integer(scheduled_event_id, :checkback_id),
         {:ok, event} <- Schedule.get_current_checkback(scheduled_event_id),
         :ok <- checkback_belongs_to_turn(event, turn_ref) do
      {:ok, event}
    end
  end

  defp mutate_cron_from_turn(request, %TurnRef{} = turn_ref, status, fun) do
    with :ok <- reject_cron_origin_broad_mutation(turn_ref),
         {:ok, schedule} <- cron_schedule_from_turn(request.name, turn_ref),
         {:ok, updated} <- fun.(schedule.id) do
      {:ok, %{"status" => status, "schedule" => Schedule.cron_model_projection(updated)}}
    end
  end

  defp checkback_attrs(request, %TurnRef{} = turn_ref, source, ctx, reply_route) do
    with {:ok, automation_job_id} <-
           optional_safe_integer(request.automation_job_id, :automation_job_id),
         {:ok, attrs} <-
           checkback_turn_attrs(request, turn_ref, source, ctx, reply_route || %{}) do
      {:ok,
       Map.merge(attrs, %{
         "schedule" => Common.decode_json_bytes(request.schedule_json),
         "reason" => presence(request.reason),
         "check" => presence(request.check),
         "context_summary" => presence(request.context_summary),
         "quiet_success" => request.quiet_success,
         "automation_job_id" => automation_job_id
       })}
    end
  end

  defp checkback_update_attrs(request, %TurnRef{} = turn_ref, source, ctx, reply_route) do
    with {:ok, updates} <- checkback_updates(request),
         {:ok, attrs} <- checkback_turn_attrs(request, turn_ref, source, ctx, reply_route || %{}) do
      {:ok, Map.merge(updates, attrs)}
    end
  end

  defp checkback_turn_attrs(request, turn_ref, source, ctx, reply_route) do
    with {:ok, tool_call_id} <- required_text(request.tool_call_id, :tool_call_id),
         {:ok, idempotency_key} <- required_text(request.idempotency_key, :idempotency_key) do
      {:ok,
       %{
         "agent_uid" => turn_ref.agent_uid,
         "session_id" => turn_ref.session_id,
         "binding_name" => RPCWire.text(reply_route, "binding_name") || source.binding_name,
         "tool_call_id" => tool_call_id,
         "idempotency_key" => idempotency_key,
         "reply_route" => reply_route,
         # Source tables: current_ai_message_id resolves ai_gateway_messages.id;
         # source.actor_event_id is the actor_events.id currently being served.
         "origin_ai_message_id" => current_ai_message_id(turn_ref),
         "source_actor_event_id" => source.actor_event_id,
         "source_provenance" => %{
           "rpc_request_id" => ctx.request_id,
           "transport_route" => ctx.route,
           # Source table: these fence values are copied from the turn_ref
           # originally produced from actor_session_activations.
           "activation_uid" => turn_ref.activation_uid,
           "actor_epoch" => turn_ref.actor_epoch,
           "revision" => turn_ref.revision
         }
       }}
    end
  end

  defp checkback_updates(request) do
    case Common.decode_json_bytes(request.updates_json) do
      updates when is_map(updates) and map_size(updates) > 0 ->
        updates = RPCWire.stringify_keys(updates)
        allowed = ~w(reason check context_summary quiet_success schedule automation_job_id)

        case Map.keys(updates) -- allowed do
          [] -> {:ok, updates}
          unknown -> {:error, {:unknown_checkback_update_fields, Enum.sort(unknown)}}
        end

      _updates ->
        {:error, :checkback_update_required}
    end
  end

  defp cron_attrs(request, %TurnRef{} = turn_ref) do
    delivery = Common.decode_json_bytes(request.delivery_json)

    with {:ok, idempotency_key} <- required_text(request.idempotency_key, :idempotency_key),
         {:ok, binding_name} <- required_text(request.binding_name, :binding_name),
         {:ok, name} <- required_text(request.name, :name),
         {:ok, automation_job_id} <-
           optional_safe_integer(request.automation_job_id, :automation_job_id),
         :ok <- validate_cron_delivery_route(turn_ref, binding_name, delivery) do
      {:ok,
       %{
         "agent_uid" => turn_ref.agent_uid,
         "session_id" => turn_ref.session_id,
         "binding_name" => binding_name,
         "name" => name,
         "schedule" => Common.decode_json_bytes(request.schedule_json),
         "payload" => Common.decode_json_bytes(request.payload_json) || %{},
         "delivery" => delivery,
         "idempotency_key" => idempotency_key,
         "automation_job_id" => automation_job_id
       }}
    end
  end

  defp turn_created_by(turn) do
    %{
      "kind" => "turn",
      # Source tables: actor_event_id is actor_events.id, origin_ai_message_id
      # is ai_gateway_messages.id, and activation_uid is the live activation row.
      "actor_event_id" => turn.actor_event_id,
      "origin_ai_message_id" => current_ai_message_id(turn),
      "activation_uid" => turn.activation_uid
    }
  end

  defp validate_cron_update_delivery_route(_turn, _binding_name, updates)
       when not is_map(updates),
       do: :ok

  defp validate_cron_update_delivery_route(turn, binding_name, updates) do
    case Map.has_key?(updates, "delivery") or Map.has_key?(updates, :delivery) do
      true ->
        delivery = RPCWire.value(updates, "delivery")

        if cron_delivery_route_update?(delivery),
          do: validate_cron_delivery_route(turn, binding_name, delivery),
          else: :ok

      false ->
        :ok
    end
  end

  defp validate_cron_delivery_route(_turn, _binding_name, delivery) when not is_map(delivery),
    do: :ok

  defp validate_cron_delivery_route(turn, binding_name, delivery) do
    with {:ok, source} <- ReplyRoute.source(turn),
         {:ok, [target]} <- Delivery.targets(delivery, binding_name),
         true <- cron_delivery_route_matches?(source, target) do
      :ok
    else
      false -> {:error, :reply_route_not_in_turn}
      {:ok, _targets} -> {:error, :reply_route_not_in_turn}
      {:error, _reason} = error -> error
    end
  end

  defp cron_delivery_route_matches?(source, primary_target) do
    primary_target["signal_channel_id"] == source.signal_channel_id and
      primary_target["binding_name"] == source.binding_name and
      cron_provider_thread_matches?(
        source.provider_thread_id,
        nullable_text(primary_target, "provider_thread_id")
      )
  end

  defp cron_delivery_route_update?(delivery) when is_map(delivery) do
    not is_nil(RPCWire.value(delivery, "targets")) or
      not is_nil(RPCWire.value(delivery, "signal_channel_id"))
  end

  defp cron_delivery_route_update?(_delivery), do: false

  defp cron_provider_thread_matches?(_source_thread_id, nil), do: true

  defp cron_provider_thread_matches?(source_thread_id, delivery_thread_id),
    do: delivery_thread_id == source_thread_id

  defp cron_belongs_to_turn(schedule, %TurnRef{} = turn_ref) do
    case schedule.agent_uid == turn_ref.agent_uid and schedule.session_id == turn_ref.session_id do
      true -> :ok
      false -> {:error, :cron_schedule_not_in_turn}
    end
  end

  defp checkback_belongs_to_turn(event, %TurnRef{} = turn_ref) do
    case event.kind == "check_back_later" and event.agent_uid == turn_ref.agent_uid and
           event.session_id == turn_ref.session_id do
      true -> :ok
      false -> {:error, :checkback_not_in_turn}
    end
  end

  defp reject_cron_origin_broad_mutation(turn) do
    case cron_origin_schedule_id(turn) do
      nil -> :ok
      _cron_schedule_id -> {:error, :cron_origin_broad_cron_mutation_denied}
    end
  end

  defp cron_origin_schedule_id(%TurnRef{} = turn_ref) do
    case Repo.get(ActorEvent, turn_ref.actor_event_id) do
      %ActorEvent{payload: payload} when is_map(payload) ->
        get_in(payload, ["data", "cron_schedule_id"])

      _event ->
        nil
    end
  end

  defp current_ai_message_id(%TurnRef{} = turn_ref) do
    AIGatewayLink.current_response_row_id(turn_ref)
  end

  defp rpc_status(:scheduled), do: "scheduled"
  defp rpc_status(:already_scheduled), do: "already_scheduled"

  defp checkback_quiet_success(event) do
    is_map(event.wake_payload) and Map.get(event.wake_payload, "quiet_success") == true
  end

  defp checkback_update_status(:updated), do: "updated"
  defp checkback_update_status(:already_updated), do: "already_updated"

  defp cron_create_status(:created), do: "created"
  defp cron_create_status(:already_exists), do: "already_exists"

  defp list_limit(value, default) do
    case value do
      value when is_integer(value) and value > 0 -> min(value, 100)
      _value -> default
    end
  end

  defp error_payload(request_id, reason) do
    RPCWire.error_payload(request_id, reason,
      fallback_code: "schedule_rpc_failed",
      details_json: %{"reason" => inspect(reason)}
    )
  end

  defp required_text(value, key) do
    case presence(value) do
      text when is_binary(text) -> {:ok, text}
      nil -> {:error, {:missing_text, key}}
    end
  end

  defp safe_integer(value, _key) when is_integer(value) and value in 1000..9_007_199_254_740_991,
    do: {:ok, value}

  defp safe_integer(value, key) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer in 1000..9_007_199_254_740_991 -> {:ok, integer}
      _parsed -> {:error, {:invalid_integer, key}}
    end
  end

  defp safe_integer(_value, key), do: {:error, {:invalid_integer, key}}

  defp optional_safe_integer(value, _key) when value in [nil, ""], do: {:ok, nil}
  defp optional_safe_integer(value, key), do: safe_integer(value, key)

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp nullable_text(map, key), do: RPCWire.text(map, key)
end
