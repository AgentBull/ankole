defmodule Ankole.Schedule.RPCBroker do
  @moduledoc """
  RuntimeFabric RPC entry point for worker-originated schedule requests.
  """

  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.Actors.ActorInput
  alias Ankole.Actors.ActorInputConsumption
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
           |> Enum.map(&Schedule.event_projection/1)
       }}
    end
  end

  defp dispatch(request, "cron.add", route, _request_id, authorize_turn_route) do
    with {:ok, turn} <- turn_ref(request),
         :ok <- authorize_turn_route.(turn, route, :write),
         :ok <- reject_cron_origin_broad_mutation(turn),
         {agent_uid, session_id} <- actor_identity(turn),
         {:ok, attrs} <- cron_attrs(request, turn, agent_uid, session_id),
         {:ok, %{status: status, cron_schedule: schedule}} <- Schedule.create_cron_schedule(attrs) do
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
         {:ok, updated} <-
           Schedule.update_cron_schedule(cron_schedule_id, map_value(request, "updates") || %{}) do
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
         "scheduled_event" => Schedule.event_projection(event)
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
         "source_llm_turn_id" => text(turn, "llm_turn_id"),
         "source_actor_input_id" => source.actor_input_id,
         "source_provenance" => %{
           "rpc_request_id" => text(request, "request_id"),
           "transport_route" => route,
           "activation_uid" => text(turn, "activation_uid"),
           "actor_epoch" => integer(turn, "actor_epoch"),
           "revision" => integer(turn, "revision")
         }
       }}
    end
  end

  defp cron_attrs(request, turn, agent_uid, session_id) do
    with {:ok, idempotency_key} <- required_text(request, "idempotency_key"),
         {:ok, binding_name} <- required_text(request, "binding_name") do
      {:ok,
       %{
         "agent_uid" => agent_uid,
         "session_id" => session_id,
         "binding_name" => binding_name,
         "name" => text(request, "name"),
         "schedule" => map_value(request, "schedule"),
         "payload" => map_value(request, "payload") || %{},
         "delivery" => map_value(request, "delivery"),
         "idempotency_key" => idempotency_key,
         "created_by" => %{
           "kind" => "turn",
           "llm_turn_id" => text(turn, "llm_turn_id"),
           "activation_uid" => text(turn, "activation_uid")
         },
         "failure_policy" => map_value(request, "failure_policy") || %{}
       }}
    end
  end

  defp validate_reply_route(_turn, reply_route) when not is_map(reply_route),
    do: {:error, :invalid_reply_route}

  defp validate_reply_route(turn, reply_route) do
    with {:ok, turn_row} <- fetch_turn(turn),
         source_ids <- turn_actor_input_ids(turn_row),
         {:ok, source} <- find_reply_source(source_ids, reply_route) do
      {:ok, source}
    end
  end

  defp fetch_turn(turn) do
    case Repo.get(LlmTurn, text(turn, "llm_turn_id")) do
      %LlmTurn{} = llm_turn -> {:ok, llm_turn}
      nil -> {:error, :llm_turn_not_found}
    end
  end

  defp turn_actor_input_ids(%LlmTurn{request_refs: refs}) when is_list(refs) do
    refs
    |> Enum.flat_map(fn
      %{"actor_input_id" => actor_input_id} when is_binary(actor_input_id) -> [actor_input_id]
      %{actor_input_id: actor_input_id} when is_binary(actor_input_id) -> [actor_input_id]
      _ref -> []
    end)
    |> Enum.uniq()
  end

  defp turn_actor_input_ids(_turn), do: []

  defp find_reply_source([], _reply_route), do: {:error, :reply_route_not_in_turn}

  defp find_reply_source([actor_input_id | rest], reply_route) do
    case actor_input_reply_source(actor_input_id) do
      nil ->
        find_reply_source(rest, reply_route)

      source ->
        case reply_route_matches?(source, reply_route) do
          true -> {:ok, source}
          false -> find_reply_source(rest, reply_route)
        end
    end
  end

  defp actor_input_reply_source(actor_input_id) do
    case Repo.get(ActorInput, actor_input_id) ||
           Repo.get_by(ActorInputConsumption, actor_input_id: actor_input_id) do
      %ActorInput{} = input ->
        %{
          actor_input_id: input.id,
          binding_name: input.binding_name,
          signal_channel_id: input.signal_channel_id,
          provider_thread_id: input.provider_thread_id,
          provider_entry_id: input.provider_entry_id
        }

      %ActorInputConsumption{} = input ->
        %{
          actor_input_id: input.actor_input_id,
          binding_name: input.binding_name,
          signal_channel_id: input.signal_channel_id,
          provider_thread_id: input.provider_thread_id,
          provider_entry_id: input.provider_entry_id
        }

      nil ->
        nil
    end
  end

  defp reply_route_matches?(source, reply_route) do
    text(reply_route, "binding_name") == source.binding_name and
      text(reply_route, "signal_channel_id") == source.signal_channel_id and
      nullable_text(reply_route, "provider_thread_id") == source.provider_thread_id and
      nullable_text(reply_route, "provider_entry_id") == source.provider_entry_id
  end

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
    with {:ok, %LlmTurn{request_context: context}} <- fetch_turn(turn) do
      get_in(context || %{}, ["schedule_origin", "cron_schedule_id"])
    else
      _error -> nil
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
