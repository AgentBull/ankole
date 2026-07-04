defmodule Ankole.Schedule.RPCBroker do
  @moduledoc """
  RuntimeFabric RPC entry point for worker-originated schedule requests.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Actors.ActorEvent
  alias Ankole.Repo
  alias Ankole.Schedule

  @type action :: String.t()
  @type route_authorizer :: (map(), String.t(), :read | :write -> :ok | {:error, atom()})

  @spec handle_request(action(), route_authorizer(), map(), String.t()) ::
          {:ok, map()} | {:error, map()}
  def handle_request(action, authorize_turn_route, request, route)
      when is_binary(action) and is_function(authorize_turn_route, 3) and is_map(request) and
             is_binary(route) do
    request_id = text(request, "request_id") || "schedule-rpc-#{Ecto.UUID.generate()}"

    request
    |> dispatch(action, route, request_id, authorize_turn_route)
    |> case do
      {:ok, payload} -> {:ok, Map.put_new(payload, "request_id", request_id)}
      {:error, reason} -> {:error, error_payload(request_id, reason)}
    end
  end

  def handle_request(action, _authorize_turn_route, _request, _route),
    do: {:error, error_payload("", {:invalid_schedule_rpc_request, action})}

  defp dispatch(request, "check_back_later.create", route, _request_id, authorize_turn_route) do
    with {:ok, turn} <- turn_ref(request),
         :ok <- authorize_turn_route.(turn, route, :write),
         {:ok, source} <- validate_reply_route(turn, map_value(request, "reply_route")),
         {:ok, attrs} <- checkback_attrs(request, turn, source, route),
         {:ok, %{status: status, scheduled_event: event}} <-
           Schedule.create_check_back_later(attrs) do
      {:ok,
       %{
         "status" => rpc_status(status),
         "scheduled_event_id" => event.id,
         "due_at" => DateTime.to_iso8601(event.due_at),
         "timezone" => event.timezone
       }}
    end
  end

  defp dispatch(request, "cron.list", route, _request_id, authorize_turn_route) do
    with {:ok, turn} <- turn_ref(request),
         :ok <- authorize_turn_route.(turn, route, :read),
         {agent_uid, session_id} <- actor_identity(turn) do
      {:ok,
       %{
         "status" => "ok",
         "schedules" =>
           agent_uid
           |> Schedule.list_cron_schedules(session_id)
           |> Enum.map(&Schedule.cron_projection/1)
       }}
    end
  end

  defp dispatch(request, "cron.get", route, _request_id, authorize_turn_route) do
    with {:ok, turn} <- turn_ref(request),
         :ok <- authorize_turn_route.(turn, route, :read),
         {:ok, cron_schedule_id} <- required_text(request, "cron_schedule_id"),
         {:ok, schedule} <- Schedule.get_cron_schedule(cron_schedule_id),
         :ok <- cron_belongs_to_turn(schedule, turn) do
      {:ok, %{"status" => "ok", "schedule" => Schedule.cron_projection(schedule)}}
    end
  end

  defp dispatch(request, "cron.runs", route, _request_id, authorize_turn_route) do
    with {:ok, turn} <- turn_ref(request),
         :ok <- authorize_turn_route.(turn, route, :read),
         {:ok, cron_schedule_id} <- required_text(request, "cron_schedule_id"),
         {:ok, schedule} <- Schedule.get_cron_schedule(cron_schedule_id),
         :ok <- cron_belongs_to_turn(schedule, turn) do
      {:ok,
       %{
         "status" => "ok",
         "runs" =>
           cron_schedule_id
           |> Schedule.list_cron_runs(list_limit(request, "limit", 25))
           |> Enum.map(&Schedule.event_model_projection/1)
       }}
    end
  end

  defp dispatch(request, "cron.add", route, _request_id, authorize_turn_route) do
    with {:ok, turn} <- turn_ref(request),
         :ok <- authorize_turn_route.(turn, route, :write),
         :ok <- reject_cron_origin_broad_mutation(turn),
         {agent_uid, session_id} <- actor_identity(turn),
         {:ok, attrs} <- cron_attrs(request, turn, agent_uid, session_id),
         created_by <- turn_created_by(turn),
         {:ok, %{status: status, cron_schedule: schedule}} <-
           Schedule.create_cron_schedule(attrs, created_by: created_by) do
      {:ok,
       %{"status" => cron_create_status(status), "schedule" => Schedule.cron_projection(schedule)}}
    end
  end

  defp dispatch(request, "cron.update", route, _request_id, authorize_turn_route) do
    with {:ok, turn} <- turn_ref(request),
         :ok <- authorize_turn_route.(turn, route, :write),
         :ok <- reject_cron_origin_broad_mutation(turn),
         {:ok, cron_schedule_id} <- required_text(request, "cron_schedule_id"),
         {:ok, schedule} <- Schedule.get_cron_schedule(cron_schedule_id),
         :ok <- cron_belongs_to_turn(schedule, turn),
         updates <- map_value(request, "updates") || %{},
         :ok <- validate_cron_update_delivery_route(turn, schedule.binding_name, updates),
         {:ok, updated} <-
           Schedule.update_cron_schedule(cron_schedule_id, updates) do
      {:ok, %{"status" => "updated", "schedule" => Schedule.cron_projection(updated)}}
    end
  end

  defp dispatch(request, "cron.pause", route, _request_id, authorize_turn_route) do
    mutate_cron_from_turn(
      request,
      route,
      authorize_turn_route,
      "paused",
      &Schedule.pause_cron_schedule/1
    )
  end

  defp dispatch(request, "cron.resume", route, _request_id, authorize_turn_route) do
    with {:ok, turn} <- turn_ref(request),
         :ok <- authorize_turn_route.(turn, route, :write),
         :ok <- reject_cron_origin_broad_mutation(turn),
         {:ok, cron_schedule_id} <- required_text(request, "cron_schedule_id"),
         {:ok, schedule} <- Schedule.get_cron_schedule(cron_schedule_id),
         :ok <- cron_belongs_to_turn(schedule, turn),
         {:ok, updated} <- Schedule.resume_cron_schedule(cron_schedule_id) do
      {:ok, %{"status" => "resumed", "schedule" => Schedule.cron_projection(updated)}}
    end
  end

  defp dispatch(request, "cron.remove", route, _request_id, authorize_turn_route) do
    mutate_cron_from_turn(
      request,
      route,
      authorize_turn_route,
      "removed",
      &Schedule.remove_cron_schedule/1
    )
  end

  defp dispatch(request, "cron.run", route, _request_id, authorize_turn_route) do
    with {:ok, turn} <- turn_ref(request),
         :ok <- authorize_turn_route.(turn, route, :write),
         :ok <- reject_cron_origin_broad_mutation(turn),
         {:ok, cron_schedule_id} <- required_text(request, "cron_schedule_id"),
         {:ok, schedule} <- Schedule.get_cron_schedule(cron_schedule_id),
         :ok <- cron_belongs_to_turn(schedule, turn),
         {:ok, %{status: status, scheduled_event: event}} <-
           Schedule.run_cron_schedule(cron_schedule_id) do
      {:ok,
       %{
         "status" => rpc_status(status),
         "scheduled_event" => Schedule.event_model_projection(event)
       }}
    end
  end

  defp dispatch(_request, action, _route, _request_id, _authorize_turn_route),
    do: {:error, {:unknown_schedule_action, action}}

  defp mutate_cron_from_turn(request, route, authorize_turn_route, status, fun) do
    with {:ok, turn} <- turn_ref(request),
         :ok <- authorize_turn_route.(turn, route, :write),
         :ok <- reject_cron_origin_broad_mutation(turn),
         {:ok, cron_schedule_id} <- required_text(request, "cron_schedule_id"),
         {:ok, schedule} <- Schedule.get_cron_schedule(cron_schedule_id),
         :ok <- cron_belongs_to_turn(schedule, turn),
         {:ok, updated} <- fun.(cron_schedule_id) do
      {:ok, %{"status" => status, "schedule" => Schedule.cron_projection(updated)}}
    end
  end

  defp checkback_attrs(request, turn, source, route) do
    {agent_uid, session_id} = actor_identity(turn)
    reply_route = map_value(request, "reply_route") || %{}

    with {:ok, tool_call_id} <- required_text(request, "tool_call_id"),
         {:ok, idempotency_key} <- required_text(request, "idempotency_key") do
      {:ok,
       %{
         "agent_uid" => agent_uid,
         "session_id" => session_id,
         "binding_name" => text(reply_route, "binding_name") || source.binding_name,
         "tool_call_id" => tool_call_id,
         "idempotency_key" => idempotency_key,
         "schedule" => map_value(request, "schedule"),
         "reason" => text(request, "reason"),
         "check" => text(request, "check"),
         "context_summary" => text(request, "context_summary"),
         "reply_route" => reply_route,
         # Source tables: current_ai_message_id resolves ai_gateway_messages.id;
         # source.actor_event_id is the actor_events.id currently being served.
         "origin_ai_message_id" => current_ai_message_id(turn),
         "source_actor_event_id" => source.actor_event_id,
         "source_provenance" => %{
           "rpc_request_id" => text(request, "request_id"),
           "transport_route" => route,
           # Source table: these fence values are copied from the turn_ref
           # originally produced from actor_session_activations.
           "activation_uid" => text(turn, "activation_uid"),
           "actor_epoch" => integer(turn, "actor_epoch"),
           "revision" => integer(turn, "revision")
         }
       }}
    end
  end

  defp cron_attrs(request, turn, agent_uid, session_id) do
    with {:ok, idempotency_key} <- required_text(request, "idempotency_key"),
         {:ok, binding_name} <- required_text(request, "binding_name"),
         delivery <- map_value(request, "delivery"),
         :ok <- validate_cron_delivery_route(turn, binding_name, delivery) do
      {:ok,
       %{
         "agent_uid" => agent_uid,
         "session_id" => session_id,
         "binding_name" => binding_name,
         "name" => text(request, "name"),
         "schedule" => map_value(request, "schedule"),
         "payload" => map_value(request, "payload") || %{},
         "delivery" => delivery,
         "idempotency_key" => idempotency_key,
         "failure_policy" => map_value(request, "failure_policy") || %{}
       }}
    end
  end

  defp turn_created_by(turn) do
    %{
      "kind" => "turn",
      # Source tables: actor_event_id is actor_events.id, origin_ai_message_id
      # is ai_gateway_messages.id, and activation_uid is the live activation row.
      "actor_event_id" => text(turn, "actor_event_id"),
      "origin_ai_message_id" => current_ai_message_id(turn),
      "activation_uid" => text(turn, "activation_uid")
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
      true -> validate_cron_delivery_route(turn, binding_name, map_value(updates, "delivery"))
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
    case actor_event_reply_source(text(turn, "actor_event_id")) do
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
    text(reply_route, "binding_name") == source.binding_name and
      text(reply_route, "signal_channel_id") == source.signal_channel_id and
      nullable_text(reply_route, "provider_thread_id") == source.provider_thread_id and
      nullable_text(reply_route, "source_entry_id") == source.source_entry_id
  end

  defp cron_delivery_route_matches?(source, binding_name, delivery) do
    text(delivery, "signal_channel_id") == source.signal_channel_id and
      binding_name == source.binding_name and
      cron_provider_thread_matches?(
        source.provider_thread_id,
        nullable_text(delivery, "provider_thread_id")
      )
  end

  defp cron_provider_thread_matches?(_source_thread_id, nil), do: true

  defp cron_provider_thread_matches?(source_thread_id, delivery_thread_id),
    do: delivery_thread_id == source_thread_id

  defp cron_belongs_to_turn(schedule, turn) do
    {agent_uid, session_id} = actor_identity(turn)

    case schedule.agent_uid == agent_uid and schedule.session_id == session_id do
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

  defp cron_origin_schedule_id(turn) do
    case Repo.get(ActorEvent, text(turn, "actor_event_id")) do
      %ActorEvent{payload: payload} when is_map(payload) ->
        get_in(payload, ["data", "cron_schedule_id"])

      _event ->
        nil
    end
  end

  defp turn_ref(%{"turn_ref" => turn}) when is_map(turn), do: {:ok, turn}
  defp turn_ref(%{turn_ref: turn}) when is_map(turn), do: {:ok, stringify_keys(turn)}
  defp turn_ref(%{"turn" => turn}) when is_map(turn), do: {:ok, turn}
  defp turn_ref(%{turn: turn}) when is_map(turn), do: {:ok, stringify_keys(turn)}
  defp turn_ref(_request), do: {:error, :missing_turn_ref}

  defp actor_identity(%{"actor" => %{"agent_uid" => agent_uid, "session_id" => session_id}})
       when is_binary(agent_uid) and is_binary(session_id),
       do: {String.downcase(agent_uid), session_id}

  defp actor_identity(_turn), do: {"", ""}

  defp current_ai_message_id(turn) do
    {agent_uid, _session_id} = actor_identity(turn)

    case text(turn, "actor_event_id") do
      actor_event_id when is_binary(actor_event_id) and actor_event_id != "" ->
        Message
        |> where([message], message.agent_uid == ^agent_uid)
        |> where([message], message.type == "message")
        |> where([message], message.status in ["generating", "complete"])
        |> where([message], fragment("?->>'actor_event_id'", message.metadata) == ^actor_event_id)
        |> order_by([message], desc: message.inserted_at, desc: message.id)
        |> limit(1)
        |> select([message], message.id)
        |> Repo.one()

      _missing ->
        nil
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) and is_map(value) ->
        {Atom.to_string(key), stringify_keys(value)}

      {key, value} when is_atom(key) ->
        {Atom.to_string(key), value}

      {key, value} when is_map(value) ->
        {key, stringify_keys(value)}

      pair ->
        pair
    end)
  end

  defp rpc_status(:scheduled), do: "scheduled"
  defp rpc_status(:already_scheduled), do: "already_scheduled"

  defp cron_create_status(:created), do: "created"
  defp cron_create_status(:already_exists), do: "already_exists"

  defp list_limit(map, key, default) do
    case integer(map, key) do
      value when is_integer(value) and value > 0 -> min(value, 100)
      _value -> default
    end
  end

  defp error_payload(request_id, reason) do
    %{
      "request_id" => request_id,
      "code" => error_code(reason),
      "message" => error_message(reason),
      "details_json" => %{"reason" => inspect(reason)}
    }
  end

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "schedule_rpc_failed"

  defp error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_message({reason, details}), do: "#{reason}: #{inspect(details)}"
  defp error_message(reason), do: inspect(reason)

  defp required_text(map, key) do
    case text(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:missing_text, key}}
    end
  end

  defp nullable_text(map, key), do: text(map, key)

  defp text(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _value ->
        nil
    end
  end

  defp text(_map, _key), do: nil

  defp integer(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
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

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp map_value(_map, _key), do: nil
end
