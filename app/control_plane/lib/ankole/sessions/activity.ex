defmodule Ankole.Sessions.Activity do
  @moduledoc "Native activity display rules and the work history of one Session turn."
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
    tools = data.activity_tools
    previous = Enum.find(tools, fn {tool_id, _, _} -> tool_id == id end)

    {payload, started_at} =
      case previous do
        {_id, %{"phase" => phase} = saved, at} when phase in ["completed", "failed"] ->
          {saved, at}

        {_id, _saved, at} ->
          {Map.put(payload, "duration_ms", max(System.monotonic_time(:millisecond) - at, 0)), at}

        nil ->
          {payload, System.monotonic_time(:millisecond)}
      end

    entry = {id, payload, started_at}

    tools =
      if previous,
        do:
          Enum.map(tools, fn {tool_id, _, _} = current ->
            if tool_id == id, do: entry, else: current
          end),
        else: tools ++ [entry]

    Map.put(data, :activity_tools, tools)
  end

  def complete_tool(data, id, result) do
    tools = data.activity_tools

    case Enum.find(tools, fn {tool_id, _, _} -> tool_id == id end) do
      nil ->
        data

      {_id, payload, at} ->
        payload =
          payload
          |> Map.put("phase", if(result.is_error, do: "failed", else: "completed"))
          |> Map.put("duration_ms", result.duration_ms || payload["duration_ms"])

        tools =
          Enum.map(tools, fn {tool_id, _, _} = current ->
            if tool_id == id, do: {id, payload, at}, else: current
          end)

        data |> Map.put(:activity_tools, tools) |> publish()
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

    publish_snapshot(project(data))
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

    safe = %{
      "operation_id" => payload["operation_id"],
      "phase" =>
        if(is_binary(payload["phase"]),
          do: Presentation.activity_excerpt(payload["phase"], 160)
        ),
      "label_bindings" => bindings
    }

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

  def project(%{activity_conversation_id: id, turn: %{run: run}} = data) do
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
      tools: Enum.map(data.activity_tools, fn {_id, payload, _at} -> payload end)
    }
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
