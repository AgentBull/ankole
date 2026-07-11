defmodule Ankole.Memory.RPCBroker do
  @moduledoc """
  RuntimeFabric RPC entry point for worker-originated Memory tools.

  One public function per operation, dispatched by `Ankole.SignalsGateway.ActorRuntime.RPCLane`
  after turn authorization. Note operations are denied to subagent sessions;
  search and browse additionally pin subagent turns to their delegation scope.
  """

  alias Ankole.SignalsGateway.ActorRuntime.RPCWire
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.Memory
  alias Ankole.Repo
  alias Ankole.SubagentDelegations.Schemas.Delegation

  @spec handle_note_save(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_note_save(%TurnRef{} = turn_ref, request, _route) do
    respond(request, fn ->
      with :ok <- reject_subagent(turn_ref),
           {:ok, actor_event} <- actor_event(request),
           {:ok, channel_id} <- current_channel(actor_event),
           {:ok, content} <- required_text(request, "content"),
           {:ok, note} <-
             Memory.save_note(
               turn_ref.agent_uid,
               channel_id,
               content,
               note_source(actor_event, request)
             ) do
        {:ok, %{"status" => "saved", "note" => note_projection(note)}}
      end
    end)
  end

  @spec handle_note_update(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_note_update(%TurnRef{} = turn_ref, request, _route) do
    respond(request, fn ->
      with :ok <- reject_subagent(turn_ref),
           {:ok, actor_event} <- actor_event(request),
           {:ok, channel_id} <- current_channel(actor_event),
           {:ok, note_id} <- required_text(request, "note_id"),
           {:ok, content} <- required_text(request, "content"),
           {:ok, note} <- Memory.update_note(turn_ref.agent_uid, channel_id, note_id, content) do
        {:ok, %{"status" => "updated", "note" => note_projection(note)}}
      end
    end)
  end

  @spec handle_note_forget(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_note_forget(%TurnRef{} = turn_ref, request, _route) do
    respond(request, fn ->
      with :ok <- reject_subagent(turn_ref),
           {:ok, actor_event} <- actor_event(request),
           {:ok, channel_id} <- current_channel(actor_event),
           {:ok, note_id} <- required_text(request, "note_id"),
           {:ok, note} <- Memory.forget_note(turn_ref.agent_uid, channel_id, note_id) do
        {:ok, %{"status" => "forgotten", "note" => note_projection(note)}}
      end
    end)
  end

  @spec handle_note_list(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_note_list(%TurnRef{} = turn_ref, request, _route) do
    respond(request, fn ->
      with :ok <- reject_subagent(turn_ref),
           {:ok, actor_event} <- actor_event(request),
           {:ok, channel_id} <- current_channel(actor_event) do
        {:ok,
         %{
           "status" => "ok",
           "channel_id" => channel_id,
           "notes" => Memory.list_notes(turn_ref.agent_uid, channel_id)
         }}
      end
    end)
  end

  @spec handle_search(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_search(%TurnRef{} = turn_ref, request, _route) do
    respond(request, fn ->
      with {:ok, request} <- delegation_scoped_request(turn_ref, request) do
        request
        |> Map.put("turn_ref", TurnRef.to_wire(turn_ref))
        |> Memory.search()
      end
    end)
  end

  @spec handle_browse(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_browse(%TurnRef{} = turn_ref, request, _route) do
    respond(request, fn ->
      with {:ok, request} <- delegation_scoped_request(turn_ref, request) do
        request
        |> Map.put("turn_ref", TurnRef.to_wire(turn_ref))
        |> Memory.browse()
      end
    end)
  end

  defp respond(request, fun) do
    request_id = RPCWire.text(request, "request_id") || "memory-rpc-#{Ecto.UUID.generate()}"

    case fun.() do
      {:ok, payload} -> {:ok, Map.put_new(payload, "request_id", request_id)}
      {:error, reason} -> {:error, error_payload(request_id, reason)}
    end
  end

  defp reject_subagent(%TurnRef{session_id: "subagent:" <> _id}),
    do: {:error, :subagent_memory_action_not_allowed}

  defp reject_subagent(%TurnRef{}), do: :ok

  defp delegation_scoped_request(
         %TurnRef{session_id: "subagent:" <> delegation_id} = turn_ref,
         request
       ) do
    requested_id = RPCWire.text(request, "delegation_id")
    scope = RPCWire.map_value(request, "delegation_scope", %{}) |> RPCWire.stringify_keys()

    with ^delegation_id <- requested_id,
         %Delegation{} = delegation <-
           Repo.get_by(Delegation, id: delegation_id, agent_uid: turn_ref.agent_uid),
         expected_session = delegation.session_id,
         ^expected_session <- RPCWire.text(scope, "session_id"),
         :ok <- validate_scope_channel(scope, delegation),
         %ActorEvent{} = parent_event <- Repo.get(ActorEvent, delegation.actor_event_id),
         true <-
           parent_event.agent_uid == turn_ref.agent_uid and
             parent_event.session_id == delegation.session_id do
      {:ok, Map.put(request, "actor_event", actor_event_scope(parent_event))}
    else
      _value -> {:error, :subagent_memory_scope_mismatch}
    end
  end

  defp delegation_scoped_request(%TurnRef{}, request), do: {:ok, request}

  defp validate_scope_channel(scope, delegation) do
    expected = Map.get(delegation.reply_route || %{}, "signal_channel_id")

    case {RPCWire.text(scope, "signal_channel_id"), expected} do
      {nil, nil} -> :ok
      {channel_id, channel_id} when is_binary(channel_id) -> :ok
      _value -> {:error, :subagent_memory_scope_mismatch}
    end
  end

  defp actor_event_scope(%ActorEvent{} = event) do
    %{
      "actor_event_id" => event.id,
      "binding_name" => event.binding_name,
      "signal_channel_id" => event.signal_channel_id,
      "provider_thread_id" => event.provider_thread_id,
      "source_entry_id" => event.source_entry_id,
      "payload_json" => event.payload || %{}
    }
  end

  defp actor_event(request) do
    case Map.get(request, "actor_event") || Map.get(request, :actor_event) do
      event when is_map(event) -> {:ok, RPCWire.stringify_keys(event)}
      _value -> {:error, :missing_actor_event}
    end
  end

  defp current_channel(%{"signal_channel_id" => channel_id}) when is_binary(channel_id),
    do: {:ok, channel_id}

  defp current_channel(_actor_event), do: {:error, :missing_current_channel}

  defp note_source(actor_event, request) do
    %{
      "actor_event_id" => Map.get(actor_event, "actor_event_id"),
      "source_entry_id" => Map.get(actor_event, "source_entry_id"),
      "tool_call_id" => RPCWire.text(request, "tool_call_id")
    }
  end

  defp note_projection(note) do
    %{
      "id" => note.id,
      "agent_uid" => note.agent_uid,
      "channel_id" => note.signal_channel_id,
      "content" => note.content,
      "source" => note.source || %{},
      "created_at" => datetime(note.inserted_at),
      "updated_at" => datetime(note.updated_at)
    }
  end

  defp required_text(map, key) do
    case RPCWire.text(map, key) do
      value when is_binary(value) -> {:ok, value}
      _value -> {:error, {:missing, key}}
    end
  end

  defp error_payload(request_id, reason) do
    RPCWire.error_payload(request_id, reason,
      fallback_code: "memory_request_failed",
      message_style: :tuple_reason,
      details_json: error_details(reason)
    )
  end

  defp error_details({_reason, details}) when is_map(details), do: details
  defp error_details({_reason, details}), do: %{"reason" => inspect(details)}
  defp error_details(_reason), do: %{}

  defp datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp datetime(_value), do: nil
end
