defmodule Ankole.Memory.RPCBroker do
  @moduledoc """
  RuntimeFabric RPC entry point for worker-originated Memory tools.
  """

  alias Ankole.ActorRuntime.TurnRef
  alias Ankole.Memory

  @type action :: String.t()

  @spec handle_request(action(), TurnRef.t(), map(), String.t()) ::
          {:ok, map()} | {:error, map()}
  def handle_request(action, %TurnRef{} = turn_ref, request, _route)
      when is_binary(action) and is_map(request) do
    request_id = text(request, "request_id") || "memory-rpc-#{Ecto.UUID.generate()}"

    request
    |> dispatch(action, turn_ref)
    |> case do
      {:ok, payload} -> {:ok, Map.put_new(payload, "request_id", request_id)}
      {:error, reason} -> {:error, error_payload(request_id, reason)}
    end
  end

  def handle_request(action, _turn_ref, _request, _route),
    do: {:error, error_payload("", {:invalid_memory_rpc_request, action})}

  defp dispatch(request, "memory_note.save", %TurnRef{} = turn_ref) do
    with {:ok, actor_event} <- actor_event(request),
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
  end

  defp dispatch(request, "memory_note.update", %TurnRef{} = turn_ref) do
    with {:ok, actor_event} <- actor_event(request),
         {:ok, channel_id} <- current_channel(actor_event),
         {:ok, note_id} <- required_text(request, "note_id"),
         {:ok, content} <- required_text(request, "content"),
         {:ok, note} <- Memory.update_note(turn_ref.agent_uid, channel_id, note_id, content) do
      {:ok, %{"status" => "updated", "note" => note_projection(note)}}
    end
  end

  defp dispatch(request, "memory_note.forget", %TurnRef{} = turn_ref) do
    with {:ok, actor_event} <- actor_event(request),
         {:ok, channel_id} <- current_channel(actor_event),
         {:ok, note_id} <- required_text(request, "note_id"),
         {:ok, note} <- Memory.forget_note(turn_ref.agent_uid, channel_id, note_id) do
      {:ok, %{"status" => "forgotten", "note" => note_projection(note)}}
    end
  end

  defp dispatch(request, "memory_note.list", %TurnRef{} = turn_ref) do
    with {:ok, actor_event} <- actor_event(request),
         {:ok, channel_id} <- current_channel(actor_event) do
      {:ok,
       %{
         "status" => "ok",
         "channel_id" => channel_id,
         "notes" => Memory.list_notes(turn_ref.agent_uid, channel_id)
       }}
    end
  end

  defp dispatch(request, "memory_search", %TurnRef{} = turn_ref) do
    request
    |> Map.put("turn_ref", turn_ref)
    |> Memory.search()
  end

  defp dispatch(request, "memory_browse", %TurnRef{} = turn_ref) do
    request
    |> Map.put("turn_ref", turn_ref)
    |> Memory.browse()
  end

  defp dispatch(_request, action, _turn_ref),
    do: {:error, {:unknown_memory_action, action}}

  defp actor_event(request) do
    case Map.get(request, "actor_event") || Map.get(request, :actor_event) do
      event when is_map(event) -> {:ok, stringify_keys(event)}
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
      "tool_call_id" => text(request, "tool_call_id")
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
    case text(map, key) do
      value when is_binary(value) -> {:ok, value}
      _value -> {:error, {:missing, key}}
    end
  end

  defp text(map, key) do
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

  defp error_payload(request_id, reason) do
    %{
      "request_id" => request_id,
      "code" => error_code(reason),
      "message" => error_message(reason),
      "details_json" => error_details(reason)
    }
  end

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "memory_request_failed"

  defp error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_message({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_message(reason), do: inspect(reason)

  defp error_details({_reason, details}) when is_map(details), do: details
  defp error_details({_reason, details}), do: %{"reason" => inspect(details)}
  defp error_details(_reason), do: %{}

  defp datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp datetime(_value), do: nil
end
