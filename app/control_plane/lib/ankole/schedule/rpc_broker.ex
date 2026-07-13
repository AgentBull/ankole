defmodule Ankole.Schedule.RPCBroker do
  @moduledoc """
  RuntimeFabric RPC entry point for worker-originated schedule requests.

  One public function per operation, dispatched by `Ankole.SignalsGateway.ActorRuntime.RPCLane`
  after turn authorization.
  """

  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.AIGatewayLink
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.Repo
  alias Ankole.Schedule

  @spec handle_check_back_later_create(TurnRef.t(), map(), String.t()) ::
          {:ok, map()} | {:error, map()}
  def handle_check_back_later_create(%TurnRef{} = turn_ref, request, route) do
    respond(request, fn ->
      with {:ok, source} <- validate_reply_route(turn_ref, RPCWire.value(request, "reply_route")),
           {:ok, attrs} <- checkback_attrs(request, turn_ref, source, route),
           {:ok, %{status: status, scheduled_event: event}} <-
             Schedule.create_check_back_later(attrs) do
        {:ok,
         %{
           "status" => rpc_status(status),
           "scheduled_event_id" => event.id,
           "due_at" => DateTime.to_iso8601(event.due_at),
           "timezone" => event.timezone,
           "quiet_success" => checkback_quiet_success(event)
         }}
      end
    end)
  end

  @spec handle_cron_list(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_cron_list(%TurnRef{} = turn_ref, request, _route) do
    respond(request, fn ->
      {:ok,
       %{
         "status" => "ok",
         "schedules" =>
           turn_ref.agent_uid
           |> Schedule.list_cron_schedules(turn_ref.session_id)
           |> Enum.map(&Schedule.cron_projection/1)
       }}
    end)
  end

  @spec handle_cron_get(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_cron_get(%TurnRef{} = turn_ref, request, _route) do
    respond(request, fn ->
      with {:ok, schedule} <- cron_schedule_from_turn(request, turn_ref) do
        {:ok, %{"status" => "ok", "schedule" => Schedule.cron_projection(schedule)}}
      end
    end)
  end

  @spec handle_cron_runs(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_cron_runs(%TurnRef{} = turn_ref, request, _route) do
    respond(request, fn ->
      with {:ok, schedule} <- cron_schedule_from_turn(request, turn_ref) do
        {:ok,
         %{
           "status" => "ok",
           "runs" =>
             schedule.id
             |> Schedule.list_cron_runs(list_limit(request, "limit", 25))
             |> Enum.map(&Schedule.event_model_projection/1)
         }}
      end
    end)
  end

  @spec handle_cron_add(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_cron_add(%TurnRef{} = turn_ref, request, _route) do
    respond(request, fn ->
      with :ok <- reject_cron_origin_broad_mutation(turn_ref),
           {:ok, attrs} <- cron_attrs(request, turn_ref),
           created_by <- turn_created_by(turn_ref),
           {:ok, %{status: status, cron_schedule: schedule}} <-
             Schedule.create_cron_schedule(attrs, created_by: created_by) do
        {:ok,
         %{
           "status" => cron_create_status(status),
           "schedule" => Schedule.cron_projection(schedule)
         }}
      end
    end)
  end

  @spec handle_cron_update(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_cron_update(%TurnRef{} = turn_ref, request, _route) do
    respond(request, fn ->
      with :ok <- reject_cron_origin_broad_mutation(turn_ref),
           {:ok, schedule} <- cron_schedule_from_turn(request, turn_ref),
           updates <- RPCWire.value(request, "updates") || %{},
           :ok <- validate_cron_update_delivery_route(turn_ref, schedule.binding_name, updates),
           {:ok, updated} <- Schedule.update_cron_schedule(schedule.id, updates) do
        {:ok, %{"status" => "updated", "schedule" => Schedule.cron_projection(updated)}}
      end
    end)
  end

  @spec handle_cron_pause(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_cron_pause(%TurnRef{} = turn_ref, request, _route) do
    respond(request, fn ->
      mutate_cron_from_turn(request, turn_ref, "paused", &Schedule.pause_cron_schedule/1)
    end)
  end

  @spec handle_cron_resume(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_cron_resume(%TurnRef{} = turn_ref, request, _route) do
    respond(request, fn ->
      mutate_cron_from_turn(request, turn_ref, "resumed", &Schedule.resume_cron_schedule/1)
    end)
  end

  @spec handle_cron_remove(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_cron_remove(%TurnRef{} = turn_ref, request, _route) do
    respond(request, fn ->
      mutate_cron_from_turn(request, turn_ref, "removed", &Schedule.remove_cron_schedule/1)
    end)
  end

  @spec handle_cron_run(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_cron_run(%TurnRef{} = turn_ref, request, _route) do
    respond(request, fn ->
      with :ok <- reject_cron_origin_broad_mutation(turn_ref),
           {:ok, schedule} <- cron_schedule_from_turn(request, turn_ref),
           {:ok, %{status: status, scheduled_event: event}} <-
             Schedule.run_cron_schedule(schedule.id) do
        {:ok,
         %{
           "status" => rpc_status(status),
           "scheduled_event" => Schedule.event_model_projection(event)
         }}
      end
    end)
  end

  defp respond(request, fun) do
    request_id = RPCWire.text(request, "request_id") || "schedule-rpc-#{Ecto.UUID.generate()}"

    case fun.() do
      {:ok, payload} -> {:ok, Map.put_new(payload, "request_id", request_id)}
      {:error, reason} -> {:error, error_payload(request_id, reason)}
    end
  end

  defp cron_schedule_from_turn(request, %TurnRef{} = turn_ref) do
    with {:ok, cron_schedule_id} <- required_text(request, "cron_schedule_id"),
         {:ok, schedule} <- Schedule.get_cron_schedule(cron_schedule_id),
         :ok <- cron_belongs_to_turn(schedule, turn_ref) do
      {:ok, schedule}
    end
  end

  defp mutate_cron_from_turn(request, %TurnRef{} = turn_ref, status, fun) do
    with :ok <- reject_cron_origin_broad_mutation(turn_ref),
         {:ok, schedule} <- cron_schedule_from_turn(request, turn_ref),
         {:ok, updated} <- fun.(schedule.id) do
      {:ok, %{"status" => status, "schedule" => Schedule.cron_projection(updated)}}
    end
  end

  defp checkback_attrs(request, %TurnRef{} = turn_ref, source, route) do
    reply_route = RPCWire.value(request, "reply_route") || %{}

    with {:ok, tool_call_id} <- required_text(request, "tool_call_id"),
         {:ok, idempotency_key} <- required_text(request, "idempotency_key"),
         {:ok, quiet_success} <- optional_boolean(request, "quiet_success", false) do
      {:ok,
       %{
         "agent_uid" => turn_ref.agent_uid,
         "session_id" => turn_ref.session_id,
         "binding_name" => RPCWire.text(reply_route, "binding_name") || source.binding_name,
         "tool_call_id" => tool_call_id,
         "idempotency_key" => idempotency_key,
         "schedule" => RPCWire.value(request, "schedule"),
         "reason" => RPCWire.text(request, "reason"),
         "check" => RPCWire.text(request, "check"),
         "context_summary" => RPCWire.text(request, "context_summary"),
         "quiet_success" => quiet_success,
         "reply_route" => reply_route,
         # Source tables: current_ai_message_id resolves ai_gateway_messages.id;
         # source.actor_event_id is the actor_events.id currently being served.
         "origin_ai_message_id" => current_ai_message_id(turn_ref),
         "source_actor_event_id" => source.actor_event_id,
         "source_provenance" => %{
           "rpc_request_id" => RPCWire.text(request, "request_id"),
           "transport_route" => route,
           # Source table: these fence values are copied from the turn_ref
           # originally produced from actor_session_activations.
           "activation_uid" => turn_ref.activation_uid,
           "actor_epoch" => turn_ref.actor_epoch,
           "revision" => turn_ref.revision
         }
       }}
    end
  end

  defp cron_attrs(request, %TurnRef{} = turn_ref) do
    with {:ok, idempotency_key} <- required_text(request, "idempotency_key"),
         {:ok, binding_name} <- required_text(request, "binding_name"),
         delivery <- RPCWire.value(request, "delivery"),
         :ok <- validate_cron_delivery_route(turn_ref, binding_name, delivery) do
      {:ok,
       %{
         "agent_uid" => turn_ref.agent_uid,
         "session_id" => turn_ref.session_id,
         "binding_name" => binding_name,
         "name" => RPCWire.text(request, "name"),
         "schedule" => RPCWire.value(request, "schedule"),
         "payload" => RPCWire.value(request, "payload") || %{},
         "delivery" => delivery,
         "idempotency_key" => idempotency_key,
         "failure_policy" => RPCWire.value(request, "failure_policy") || %{}
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

  defp validate_reply_route(_turn, reply_route) when not is_map(reply_route),
    do: {:error, :invalid_reply_route}

  defp validate_reply_route(turn, reply_route) do
    with {:ok, source} <- turn_reply_source(turn),
         true <- reply_route_matches?(source, reply_route) do
      {:ok, source}
    else
      false -> {:error, :reply_route_not_in_turn}
      {:error, _reason} = error -> error
    end
  end

  defp validate_cron_update_delivery_route(_turn, _binding_name, updates)
       when not is_map(updates),
       do: :ok

  defp validate_cron_update_delivery_route(turn, binding_name, updates) do
    case Map.has_key?(updates, "delivery") or Map.has_key?(updates, :delivery) do
      true -> validate_cron_delivery_route(turn, binding_name, RPCWire.value(updates, "delivery"))
      false -> :ok
    end
  end

  defp validate_cron_delivery_route(_turn, _binding_name, delivery) when not is_map(delivery),
    do: :ok

  defp validate_cron_delivery_route(turn, binding_name, delivery) do
    with {:ok, source} <- turn_reply_source(turn),
         true <- cron_delivery_route_matches?(source, binding_name, delivery) do
      :ok
    else
      false -> {:error, :reply_route_not_in_turn}
      {:error, _reason} = error -> error
    end
  end

  defp turn_reply_source(turn) do
    case actor_event_reply_source(turn.actor_event_id) do
      nil -> {:error, :reply_route_not_in_turn}
      source -> {:ok, source}
    end
  end

  defp actor_event_reply_source(actor_event_id) do
    case Repo.get(ActorEvent, actor_event_id) do
      %ActorEvent{} = input ->
        %{
          actor_event_id: input.id,
          binding_name: input.binding_name,
          signal_channel_id: input.signal_channel_id,
          provider_thread_id: input.provider_thread_id,
          source_entry_id: input.source_entry_id
        }

      nil ->
        nil
    end
  end

  defp reply_route_matches?(source, reply_route) do
    RPCWire.text(reply_route, "binding_name") == source.binding_name and
      RPCWire.text(reply_route, "signal_channel_id") == source.signal_channel_id and
      nullable_text(reply_route, "provider_thread_id") == source.provider_thread_id and
      nullable_text(reply_route, "source_entry_id") == source.source_entry_id
  end

  defp cron_delivery_route_matches?(source, binding_name, delivery) do
    RPCWire.text(delivery, "signal_channel_id") == source.signal_channel_id and
      binding_name == source.binding_name and
      cron_provider_thread_matches?(
        source.provider_thread_id,
        nullable_text(delivery, "provider_thread_id")
      )
  end

  defp cron_provider_thread_matches?(_source_thread_id, nil), do: true

  defp cron_provider_thread_matches?(source_thread_id, delivery_thread_id),
    do: delivery_thread_id == source_thread_id

  defp cron_belongs_to_turn(schedule, %TurnRef{} = turn_ref) do
    case schedule.agent_uid == turn_ref.agent_uid and schedule.session_id == turn_ref.session_id do
      true -> :ok
      false -> {:error, :cron_schedule_not_in_turn}
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

  defp cron_create_status(:created), do: "created"
  defp cron_create_status(:already_exists), do: "already_exists"

  defp list_limit(map, key, default) do
    case integer(map, key) do
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

  defp required_text(map, key) do
    case RPCWire.text(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:missing_text, key}}
    end
  end

  defp optional_boolean(map, key, default) do
    case RPCWire.value(map, key) do
      nil -> {:ok, default}
      value when is_boolean(value) -> {:ok, value}
      _value -> {:error, {:invalid_boolean, key}}
    end
  end

  defp nullable_text(map, key), do: RPCWire.text(map, key)

  defp integer(map, key) when is_map(map) do
    case RPCWire.value(map, key) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_integer(value)
      _value -> nil
    end
  end

  defp integer(_map, _key), do: nil

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _value -> nil
    end
  end
end
