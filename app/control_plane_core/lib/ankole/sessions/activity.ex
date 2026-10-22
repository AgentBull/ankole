defmodule Ankole.Sessions.Activity do
  @moduledoc "Native activity display rules and bounded projections of the existing Session Driver."
  require Ash.Query
  alias Ankole.Sessions
  alias Ankole.Sessions.{Key, Presentation, Run, SessionWorkspace}
  alias Ankole.Signals.Signal

  @snapshot_timeout 250

  def native_source(run) do
    with {:conversation, id} <- Key.parse(run.session_id),
         {:ok, %{kind: :native}} <-
           Ankole.Conversations.get_conversation(id, timeout: @snapshot_timeout) do
      id
    else
      _ -> nil
    end
  end

  # Presentation normalizes Worker labels before this native-only filter.
  def present(data, %{"kind" => kind, "payload" => payload})
      when kind in ["turn.phase", "tool.activity"] and is_map(payload) do
    payload = display_payload(payload)

    data
    |> put_display(kind, payload)
    |> publish()
  end

  def present(data, _event), do: data

  defp put_display(data, "turn.phase", payload), do: %{data | phase: payload}

  defp put_display(data, "tool.activity", payload) do
    id = payload["operation_id"]

    if Map.has_key?(data.turn.pending, id) do
      previous = data.turn.pending[id].activity

      activity =
        if previous && previous["phase"] in ["completed", "failed"],
          do: previous,
          else: payload

      %{
        data
        | turn: %{
            data.turn
            | pending: Map.update!(data.turn.pending, id, &%{&1 | activity: activity})
          }
      }
    else
      data
    end
  end

  def publish(data) do
    data = %{data | activity_revision: data.activity_revision + 1}
    publish_snapshot(project(data))
    data
  end

  def clear(%{turn: %{run: nil}} = data, _state), do: data

  def clear(data, state) do
    data = %{
      data
      | phase: nil,
        activity_revision: data.activity_revision + 1,
        activity_state: state
    }

    publish_snapshot(project(%{data | turn: %{data.turn | pending: %{}}}))
    data
  end

  defp display_payload(payload) do
    key = payload["label_key"]

    key =
      if is_binary(key) and String.starts_with?(key, "conversations.delivery.reply.activity."),
        do: Presentation.activity_excerpt(key, 160)

    bindings =
      case payload["label_bindings"] do
        bindings when is_map(bindings) ->
          bindings
          |> Enum.take(8)
          |> Enum.filter(fn {key, value} ->
            is_binary(key) and (is_binary(value) or is_number(value) or is_boolean(value))
          end)
          |> Map.new(fn {key, value} ->
            {Presentation.activity_excerpt(key, 64),
             Presentation.activity_excerpt(to_string(value), 160)}
          end)

        _ ->
          %{}
      end

    safe =
      payload
      |> Enum.filter(fn
        {key, value} when key in ["operation_id", "phase", "state"] -> is_binary(value)
        {"consequential", value} -> is_boolean(value)
        _ -> false
      end)
      |> Map.new(fn {key, value} ->
        {key,
         if(is_binary(value) and key != "operation_id",
           do: Presentation.activity_excerpt(value, 160),
           else: value
         )}
      end)
      |> Map.put("label_bindings", bindings)

    cond do
      key ->
        Map.put(safe, "label_key", key)

      is_binary(payload["label"]) ->
        Map.put(safe, "label", Presentation.activity_excerpt(payload["label"], 160))

      true ->
        Map.put(safe, "label_key", "conversations.delivery.reply.activity.processing")
    end
  end

  def project(%{activity_conversation_id: nil}), do: nil
  def project(%{turn: %{run: nil}}), do: nil

  def project(%{turn: %{run: run}} = data) do
    case Key.parse(run.session_id) do
      {:conversation, id} ->
        %{
          conversationID: id,
          agentUID: run.agent_uid,
          sessionID: run.session_id,
          signalID: run.signal_id,
          epoch: run.epoch,
          revision: data.activity_revision,
          responseID: Run.response_id(run.model_response),
          state: data.activity_state,
          phase: data.phase,
          tools:
            data.turn.pending
            |> Enum.sort_by(&elem(&1, 0))
            |> Enum.flat_map(fn {_id, entry} ->
              if entry.activity && entry.activity["phase"] not in ["completed", "failed"],
                do: [entry.activity],
                else: []
            end)
            |> Enum.take(4)
        }

      _ ->
        nil
    end
  end

  def current(key) do
    pid = Sessions.driver_pid(key)
    snapshot = if is_pid(pid), do: read_driver(pid)

    cond do
      snapshot && snapshot.state == "active" && valid?(snapshot) -> {snapshot, pid}
      true -> {unavailable(key), if(is_pid(pid), do: pid)}
    end
  end

  defp publish_snapshot(nil), do: :ok

  defp publish_snapshot(snapshot) do
    if snapshot.state != "active" or valid?(snapshot) do
      Ankole.Sessions.Events.publish_activity(snapshot.agentUID, snapshot.sessionID, snapshot)
    end

    :ok
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error, ArgumentError] -> :ok
  catch
    :exit, _reason -> :ok
  end

  # Check durable epoch and open input together. The process registry alone is
  # insufficient when an old Driver survives a takeover.
  def valid?(snapshot) do
    with {:ok, %SessionWorkspace{epoch: epoch}} when epoch == snapshot.epoch <-
           workspace(snapshot.agentUID, snapshot.sessionID),
         {:ok, %Signal{} = signal} <-
           Ankole.Signals.get_signal(snapshot.signalID, timeout: @snapshot_timeout) do
      signal.agent_uid == snapshot.agentUID and signal.session_id == snapshot.sessionID and
        signal.status in [:queued, :running] and
        DateTime.compare(signal.available_at, DateTime.utc_now()) != :gt
    else
      _unavailable -> false
    end
  end

  def unavailable(key) do
    with {:ok, %SessionWorkspace{epoch: epoch}} <- workspace(key.agent_uid, key.session_id),
         {:ok, open} <-
           Ankole.Signals.list_signals(
             query: [
               filter: [
                 agent_uid: key.agent_uid,
                 session_id: key.session_id,
                 status: [in: [:queued, :running]]
               ],
               select: [:id],
               limit: 1
             ],
             timeout: @snapshot_timeout
           ) do
      fallback(key, epoch, if(open == [], do: "settled", else: "unavailable"))
    else
      _unavailable -> fallback(key, 0, "unavailable")
    end
  end

  # A snapshot read fails closed: a slow or unavailable database gives no row.
  defp workspace(agent_uid, session_id) do
    SessionWorkspace
    |> Ash.Query.filter(agent_uid == ^agent_uid and session_id == ^session_id)
    |> Ankole.Ash.read_one(timeout: @snapshot_timeout)
  end

  defp fallback(key, epoch, state) do
    {:conversation, id} = Key.parse(key.session_id)

    %{
      conversationID: id,
      agentUID: key.agent_uid,
      sessionID: key.session_id,
      signalID: nil,
      responseID: nil,
      epoch: epoch,
      revision: 0,
      state: state,
      phase: nil,
      tools: []
    }
  end

  defp read_driver(pid) do
    :gen_statem.call(pid, :activity_snapshot, @snapshot_timeout)
  catch
    :exit, _ -> nil
  end
end
