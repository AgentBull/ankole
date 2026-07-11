defmodule Ankole.SignalsGateway.ActorRuntime.SubagentDelegationBroker do
  @moduledoc """
  Turn-fenced RuntimeFabric RPC broker for durable subagent work.

  Parent turns may create and operate work visible from their current channel.
  Delegation turns may only mutate the work item encoded in their own
  `subagent:<id>` actor session. The worker route is therefore never an
  authorization boundary by itself.
  """

  alias Ankole.SignalsGateway.ActorRuntime.RPCWire
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.Repo
  alias Ankole.SubagentDelegations
  alias Ankole.SubagentDelegations.Schemas.Delegation
  alias Ankole.SubagentDelegations.Schemas.Event

  @terminal_statuses Delegation.terminal_statuses()

  @spec handle_create(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_create(%TurnRef{} = turn_ref, request, route) when is_map(request) do
    request_id = request_id(request, "create")

    with :ok <- require_parent_turn(turn_ref),
         %ActorEvent{} = actor_event <- actor_event_for_turn(turn_ref),
         attrs <-
           request
           |> Map.put("agent_uid", turn_ref.agent_uid)
           |> Map.put("session_id", turn_ref.session_id)
           |> Map.put("actor_event_id", turn_ref.actor_event_id)
           |> Map.put("reply_route", reply_route(actor_event))
           |> put_worker_route_metadata(route),
         {:ok, %{delegation: %Delegation{} = delegation}} <-
           SubagentDelegations.create_with_dispatch(attrs) do
      {:ok, delegation_payload(request_id, delegation)}
    else
      nil -> error(request_id, turn_ref.agent_uid, :actor_event_not_found)
      {:error, reason} -> error(request_id, turn_ref.agent_uid, reason)
    end
  end

  @spec handle_get(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_get(%TurnRef{} = turn_ref, request, _route) when is_map(request) do
    request_id = request_id(request, "get")
    delegation_id = RPCWire.text(request, "delegation_id") || ""

    with {:ok,
          %{
            delegation: %Delegation{} = delegation,
            last_event_seq: last_event_seq,
            attempt_history: attempt_history
          }} <-
           SubagentDelegations.get_delegation_summary_for_agent(
             delegation_id,
             turn_ref.agent_uid
           ),
         :ok <- authorize_visible_delegation(turn_ref, delegation) do
      payload =
        request_id
        |> delegation_payload(delegation)
        |> maybe_put("last_event_seq", last_event_seq)
        |> maybe_put("attempt_history", attempt_history)
        |> maybe_put_result_ref(delegation)

      {:ok, payload}
    else
      {:error, reason} -> error(request_id, turn_ref.agent_uid, reason)
    end
  end

  @spec handle_list(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_list(%TurnRef{} = turn_ref, request, _route) when is_map(request) do
    request_id = request_id(request, "list")

    with :ok <- require_parent_turn(turn_ref),
         %ActorEvent{} = actor_event <- actor_event_for_turn(turn_ref) do
      delegations =
        SubagentDelegations.list_for_channel(
          turn_ref.agent_uid,
          turn_ref.session_id,
          actor_event.signal_channel_id
        )

      {:ok,
       %{
         "request_id" => request_id,
         "delegations" => Enum.map(delegations, &delegation_summary/1)
       }}
    else
      nil -> error(request_id, turn_ref.agent_uid, :actor_event_not_found)
      {:error, reason} -> error(request_id, turn_ref.agent_uid, reason)
    end
  end

  @spec handle_append_events(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_append_events(%TurnRef{} = turn_ref, request, route) when is_map(request) do
    request_id = request_id(request, "events")
    delegation_id = RPCWire.text(request, "delegation_id") || ""
    events = list_value(request, "events", [])

    with :ok <- authorize_delegation_turn(turn_ref, delegation_id),
         {:ok, appended} <-
           SubagentDelegations.append_worker_events(
             delegation_id,
             turn_ref.agent_uid,
             events,
             turn_ref,
             route
           ) do
      {:ok,
       %{
         "request_id" => request_id,
         "delegation_id" => delegation_id,
         "events" => Enum.map(appended, &event_payload/1),
         "last_event_seq" => appended |> List.last() |> event_seq()
       }}
    else
      {:error, reason} -> error(request_id, turn_ref.agent_uid, reason)
    end
  end

  @spec handle_update_status(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_update_status(%TurnRef{} = turn_ref, request, route) when is_map(request) do
    request_id = request_id(request, "update")
    delegation_id = RPCWire.text(request, "delegation_id") || ""

    attrs =
      request
      |> Map.take(~w(status runtime_thread_id result error metadata started_at completed_at))
      |> put_worker_route_metadata(route)

    with :ok <- authorize_delegation_turn(turn_ref, delegation_id),
         {:ok, %{delegation: %Delegation{} = delegation}} <-
           SubagentDelegations.commit_status_with_wakeup(
             delegation_id,
             turn_ref.agent_uid,
             attrs,
             turn_ref: turn_ref,
             worker_route: route
           ) do
      {:ok, delegation_payload(request_id, delegation)}
    else
      {:error, reason} -> error(request_id, turn_ref.agent_uid, reason)
    end
  end

  @spec handle_stop(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_stop(%TurnRef{} = turn_ref, request, _route) when is_map(request) do
    request_id = request_id(request, "stop")
    delegation_id = RPCWire.text(request, "delegation_id") || ""

    with %Delegation{} = delegation <-
           SubagentDelegations.get_delegation_for_agent(delegation_id, turn_ref.agent_uid),
         :ok <- authorize_visible_delegation(turn_ref, delegation),
         {:ok, %{delegation: %Delegation{} = delegation}} <-
           SubagentDelegations.request_stop(delegation_id, %{
             "agent_uid" => turn_ref.agent_uid,
             "request_id" => request_id,
             "cancel_requested_by" => "agent:#{turn_ref.agent_uid}",
             "reason" => RPCWire.text(request, "reason")
           }) do
      {:ok, delegation_payload(request_id, delegation)}
    else
      nil -> error(request_id, turn_ref.agent_uid, :delegation_not_found)
      {:error, reason} -> error(request_id, turn_ref.agent_uid, reason)
    end
  end

  @spec handle_steer(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_steer(%TurnRef{} = turn_ref, request, _route) when is_map(request) do
    request_id = request_id(request, "steer")
    delegation_id = RPCWire.text(request, "delegation_id") || ""

    with %Delegation{} = delegation <-
           SubagentDelegations.get_delegation_for_agent(delegation_id, turn_ref.agent_uid),
         :ok <- authorize_visible_delegation(turn_ref, delegation),
         {:ok, %{delegation: %Delegation{} = delegation}} <-
           SubagentDelegations.request_steer(delegation_id, %{
             "agent_uid" => turn_ref.agent_uid,
             "request_id" => request_id,
             "text" => RPCWire.text(request, "text"),
             "answers" => RPCWire.map_value(request, "answers", %{})
           }) do
      {:ok, delegation_payload(request_id, delegation)}
    else
      nil -> error(request_id, turn_ref.agent_uid, :delegation_not_found)
      {:error, reason} -> error(request_id, turn_ref.agent_uid, reason)
    end
  end

  defp authorize_visible_delegation(%TurnRef{} = turn_ref, %Delegation{} = delegation) do
    cond do
      turn_ref.session_id == "subagent:#{delegation.id}" ->
        :ok

      String.starts_with?(turn_ref.session_id, "subagent:") ->
        {:error, :subagent_delegation_scope_mismatch}

      delegation.session_id == turn_ref.session_id ->
        :ok

      true ->
        authorize_same_channel(turn_ref, delegation)
    end
  end

  defp authorize_same_channel(turn_ref, delegation) do
    with %ActorEvent{signal_channel_id: channel_id} when is_binary(channel_id) <-
           actor_event_for_turn(turn_ref),
         ^channel_id when is_binary(channel_id) <-
           Map.get(delegation.reply_route || %{}, "signal_channel_id") do
      :ok
    else
      _value -> {:error, :subagent_delegation_scope_mismatch}
    end
  end

  defp authorize_delegation_turn(%TurnRef{} = turn_ref, delegation_id) do
    case turn_ref.session_id do
      "subagent:" <> ^delegation_id -> :ok
      _session_id -> {:error, :subagent_delegation_turn_mismatch}
    end
  end

  defp require_parent_turn(%TurnRef{session_id: "subagent:" <> _delegation_id}),
    do: {:error, :subagent_parent_turn_required}

  defp require_parent_turn(%TurnRef{}), do: :ok

  defp actor_event_for_turn(%TurnRef{} = turn_ref) do
    case Repo.get(ActorEvent, turn_ref.actor_event_id) do
      %ActorEvent{agent_uid: agent_uid, session_id: session_id} = event
      when agent_uid == turn_ref.agent_uid and session_id == turn_ref.session_id ->
        event

      _event ->
        nil
    end
  end

  defp reply_route(actor_event) do
    %{
      "binding_name" => actor_event.binding_name,
      "signal_channel_id" => actor_event.signal_channel_id,
      "provider_thread_id" => actor_event.provider_thread_id,
      "source_entry_id" => actor_event.source_entry_id
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp delegation_payload(request_id, %Delegation{} = delegation) do
    %{
      "request_id" => request_id,
      "delegation_id" => delegation.id,
      "agent_uid" => delegation.agent_uid,
      "session_id" => delegation.session_id,
      "actor_event_id" => delegation.actor_event_id,
      "tool_call_id" => delegation.tool_call_id,
      "workdir" => delegation.workdir,
      "status" => delegation.status,
      "runtime_thread_id" => delegation.runtime_thread_id,
      "runtime" => delegation.runtime,
      "codex_account_id" => delegation.codex_account_id,
      "title" => delegation.title,
      "task" => delegation.task,
      "background" => delegation.background,
      "notes" => delegation.notes,
      "reply_route" => delegation.reply_route,
      "attempts" => delegation.attempts,
      "queued_at" => iso8601(delegation.queued_at),
      "started_at" => iso8601(delegation.started_at),
      "completed_at" => iso8601(delegation.completed_at),
      "result" => delegation.result || %{},
      "error" => delegation.error || %{},
      "metadata" => delegation.metadata || %{}
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp delegation_summary(%Delegation{} = delegation) do
    %{
      "delegation_id" => delegation.id,
      "title" => delegation.title,
      "status" => delegation.status,
      "runtime" => delegation.runtime,
      "attempts" => delegation.attempts,
      "queued_at" => iso8601(delegation.queued_at),
      "started_at" => iso8601(delegation.started_at),
      "completed_at" => iso8601(delegation.completed_at)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp event_payload(%Event{} = event) do
    %{"event_id" => event.id, "seq" => event.seq}
  end

  defp event_seq(%Event{seq: seq}), do: seq
  defp event_seq(nil), do: nil

  defp request_id(request, action) do
    RPCWire.text(request, "request_id") ||
      "subagent-delegation-#{action}-#{Ecto.UUID.generate()}"
  end

  defp error(request_id, agent_uid, reason) do
    {:error,
     RPCWire.error_payload(request_id, reason,
       fallback_code: "subagent_delegation_failed",
       changeset_code: "invalid_subagent_delegation",
       message_style: :tuple_inspect,
       details_json: %{"agent_uid" => agent_uid}
     )}
  end

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_result_ref(map, %Delegation{status: status, id: id})
       when status in @terminal_statuses do
    Map.put(map, "result_ref", %{"type" => "subagent_delegation", "delegation_id" => id})
  end

  defp maybe_put_result_ref(map, %Delegation{}), do: map

  defp put_worker_route_metadata(map, route) when is_map(map) and is_binary(route) do
    metadata = RPCWire.map_value(map, "metadata", %{})
    Map.put(map, "metadata", Map.put(metadata, "worker_route", route))
  end

  defp put_worker_route_metadata(map, _route), do: map

  defp list_value(map, key, default) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_list(value) -> value
      _value -> default
    end
  end
end
