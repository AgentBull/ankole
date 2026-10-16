defmodule AnkoleWeb.PodStream do
  @moduledoc "Streams committed conversation changes, live text, and bounded current activity."
  import Plug.Conn
  alias Ankole.AIGateway.Events
  alias Ankole.Conversations
  alias Ankole.Sessions.Activity
  @ping_interval 15_000

  def open(
        conn,
        %{conversation: conversation, agent: agent, model_conversation_id: model_id} = detail
      ) do
    :ok = Conversations.subscribe(conversation.id)

    case Events.subscribe(agent.uid, model_id) do
      :ok ->
        key = %{agent_uid: agent.uid, session_id: detail.session_id}
        # Subscription precedes the snapshot; revisions reject queued older observations.
        {activity, pid} = Activity.current(key)

        scope = %{
          id: conversation.id,
          agent: agent.uid,
          model: model_id,
          key: key,
          response: nil,
          activity: activity,
          monitor: if(pid, do: Process.monitor(pid)),
          driver: pid,
          retired_driver: nil
        }

        stream(conn, scope)

      {:error, _reason} ->
        :ok = Conversations.unsubscribe(conversation.id)
        {:error, :conversation_not_found}
    end
  end

  defp stream(conn, scope) do
    try do
      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "private, no-store")
        |> put_resp_header("x-accel-buffering", "no")
        |> send_chunked(200)

      {:ok, write(conn, [": ping\n\n", frame(:activity, scope.activity)], scope, next_ping())}
    after
      if scope.monitor, do: Process.demonitor(scope.monitor, [:flush])
      :ok = Events.unsubscribe(scope.agent, scope.model)
      :ok = Conversations.unsubscribe(scope.id)
    end
  end

  defp loop(conn, scope, ping_at) do
    remaining = ping_at - System.monotonic_time(:millisecond)

    if remaining > 0,
      do: receive_event(conn, scope, ping_at, remaining),
      else: write(conn, ": ping\n\n", scope, next_ping())
  end

  defp receive_event(
         conn,
         %{id: id, agent: agent, model: model, monitor: monitor} = scope,
         ping_at,
         remaining
       ) do
    receive do
      {:conversation_event, ^id, event} when event in [:message, :status] ->
        {snapshot, pid} = Activity.current(scope.key)
        scope = monitor_driver(scope, pid)
        {activity, changed?} = merge_activity(scope.activity, snapshot, true)
        frames = [frame(event, %{}), if(changed?, do: frame(:activity, activity), else: [])]
        write(conn, frames, %{scope | activity: activity}, ping_at)

      {:conversation_event, ^id, {:activity, publisher, snapshot}} ->
        if snapshot.agentUID == agent and snapshot.sessionID == scope.key.session_id and
             (snapshot.state != "active" or
                (publisher != scope.retired_driver and
                   publisher == Ankole.Sessions.driver_pid(scope.key) and
                   Activity.valid?(snapshot))) do
          {activity, changed?} = merge_activity(scope.activity, snapshot)

          if changed?,
            do:
              write(
                conn,
                frame(:activity, activity),
                monitor_driver(
                  %{scope | activity: activity},
                  Ankole.Sessions.driver_pid(scope.key)
                ),
                ping_at
              ),
            else: loop(conn, scope, ping_at)
        else
          loop(conn, scope, ping_at)
        end

      {:DOWN, ^monitor, :process, pid, _reason} when not is_nil(monitor) ->
        activity = %{scope.activity | state: "unavailable", phase: nil, tools: []}

        write(
          conn,
          frame(:activity, activity),
          %{scope | activity: activity, monitor: nil, driver: nil, retired_driver: pid},
          ping_at
        )

      {:ai_gateway_event, event, %{subject_uid: ^agent, conversation_id: ^model} = gateway} ->
        write_gateway_event(conn, event, gateway, scope, ping_at)
    after
      remaining -> write(conn, ": ping\n\n", scope, next_ping())
    end
  end

  def merge_activity(current, incoming, fresh_read? \\ false) do
    # A failed diagnostic read has no revision of its own. Clear the display
    # without lowering the watermark that rejects already in-flight snapshots.
    incoming =
      if incoming.state == "unavailable" and incoming.epoch in [0, current.epoch],
        do: %{incoming | epoch: current.epoch, revision: max(incoming.revision, current.revision)},
        else: incoming

    cond do
      incoming.epoch < current.epoch ->
        {current, false}

      incoming.epoch == current.epoch and current.state == "settled" ->
        {current, false}

      incoming.epoch == current.epoch and incoming.state == "active" and
          (incoming.revision < current.revision or
             (incoming.revision == current.revision and
                not (fresh_read? and current.state == "unavailable"))) ->
        {current, false}

      true ->
        {incoming, incoming != current}
    end
  end

  defp write_gateway_event(conn, :response_started, gateway, scope, ping_at) do
    {signal_ids, scope} = response_inputs(gateway, scope)

    write(
      conn,
      frame(:started, %{responseID: gateway.response_id, signalIDs: signal_ids}),
      scope,
      ping_at
    )
  end

  defp write_gateway_event(
         conn,
         :output_text_delta,
         %{response_id: id, payload: %{text: text}} = gateway,
         scope,
         ping_at
       )
       when is_binary(text) do
    {signal_ids, scope} = response_inputs(gateway, scope)

    write(
      conn,
      frame(:delta, %{responseID: id, signalIDs: signal_ids, text: text}),
      scope,
      ping_at
    )
  end

  defp write_gateway_event(conn, _event, _payload, scope, ping_at), do: loop(conn, scope, ping_at)

  defp response_inputs(%{response_id: id}, %{response: {id, signal_ids}} = scope),
    do: {signal_ids, scope}

  defp response_inputs(gateway, scope) do
    signal_ids = Ankole.Sessions.response_signal_ids(gateway)
    {signal_ids, %{scope | response: {gateway.response_id, signal_ids}}}
  end

  defp monitor_driver(%{driver: pid} = scope, pid), do: scope

  defp monitor_driver(scope, pid) do
    if scope.monitor, do: Process.demonitor(scope.monitor, [:flush])

    if is_pid(pid),
      do: %{scope | driver: pid, monitor: Process.monitor(pid)},
      else: %{scope | driver: nil, monitor: nil}
  end

  defp write(conn, data, scope, ping_at) do
    case authorized?(conn) && chunk(conn, data) do
      {:ok, conn} ->
        loop(conn, scope, ping_at)

      closed when closed == false or elem(closed, 0) == :error ->
        if scope.monitor, do: Process.demonitor(scope.monitor, [:flush])
        conn
    end
  end

  defp authorized?(conn) do
    case AnkoleWeb.Session.pod_session(conn) do
      %{"principal_uid" => uid} -> uid == conn.assigns.current_principal_uid
      _ -> false
    end
  end

  defp frame(event, data),
    do: ["event: ", to_string(event), "\ndata: ", Ankole.JSON.encode!(data), "\n\n"]

  defp next_ping, do: System.monotonic_time(:millisecond) + @ping_interval
end
