defmodule AnkoleWeb.PodStream do
  @moduledoc "Streams room changes and the live work of every Agent in a native conversation."
  import Plug.Conn
  alias Ankole.AIGateway.Events
  alias Ankole.Conversations.Events, as: ConversationEvents
  alias Ankole.Conversations.Native
  alias Ankole.Sessions.Activity
  alias Ankole.Sessions.Events, as: SessionEvents
  @ping_interval 15_000
  @flush_interval 40

  def open(conn, %{conversation: conversation}) do
    scope = %{
      id: conversation.id,
      session: Ankole.Sessions.Key.conversation(conversation.id),
      actor: conn.assigns.authz_actor,
      access_topic: "drive-access:" <> Ankole.Repo.tenant_id!(),
      agents: %{},
      buffers: %{},
      flush_at: nil,
      ping_at: now() + @ping_interval
    }

    :ok = ConversationEvents.subscribe(scope.id)
    :ok = Phoenix.PubSub.subscribe(Ankole.PubSub, scope.access_topic)
    scope = sync_agents(scope)
    {snapshots, scope} = snapshot_frames(scope)

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    data = [frame(:connected, %{conversationID: scope.id}) | activity_frames(scope)] ++ snapshots
    {conn, scope} = write(conn, data, scope)
    Enum.each(scope.agents, fn {uid, agent} -> unsubscribe(uid, agent, scope.session) end)
    :ok = ConversationEvents.unsubscribe(scope.id)
    :ok = Phoenix.PubSub.unsubscribe(Ankole.PubSub, scope.access_topic)
    {:ok, conn}
  end

  defp loop(conn, scope) do
    deadline = min(scope.flush_at || scope.ping_at, scope.ping_at)
    receive_event(conn, scope, max(deadline - now(), 0))
  end

  defp receive_event(conn, scope, timeout) do
    id = scope.id
    session = scope.session
    agents = scope.agents
    monitors = Map.new(agents, fn {_uid, agent} -> {agent.monitor, true} end)

    receive do
      :recheck_access ->
        write(conn, ": access checked\n\n", scope)

      {:conversation_event, ^id, kind} when kind in [:message, :status] ->
        committed(conn, scope)

      {:session_event, uid, ^session, kind}
      when is_map_key(agents, uid) and (kind == :status or elem(kind, 0) == :turn_completed) ->
        committed(conn, scope)

      {:session_event, uid, ^session, {:activity, publisher, snapshot}}
      when is_map_key(agents, uid) ->
        activity(conn, scope, uid, publisher, snapshot)

      {:DOWN, ref, :process, pid, _reason} when not is_nil(ref) and is_map_key(monitors, ref) ->
        driver_down(conn, scope, ref, pid)

      {:ai_gateway_event, event, %{subject_uid: uid, conversation_id: model} = gateway}
      when is_map_key(agents, uid) and
             :erlang.map_get(:model, :erlang.map_get(uid, agents)) == model ->
        gateway_event(conn, scope, event, gateway)
    after
      timeout -> tick(conn, scope)
    end
  end

  defp tick(conn, scope) do
    if scope.flush_at && scope.flush_at <= now() do
      {frames, scope} = flush(scope)
      write(conn, frames, scope)
    else
      write(conn, ": ping\n\n", %{scope | ping_at: now() + @ping_interval})
    end
  end

  defp committed(conn, scope) do
    {buffered, scope} = flush(scope)
    previous = scope.agents
    scope = sync_agents(scope)

    changed =
      for {uid, agent} <- scope.agents,
          not Map.has_key?(previous, uid) or previous[uid].model != agent.model,
          do: uid

    {snapshots, scope} = snapshot_frames(scope, changed, true)

    write(
      conn,
      [buffered, frame(:conversation, %{conversationID: scope.id}) | activity_frames(scope)] ++
        snapshots,
      scope
    )
  end

  defp activity(conn, scope, uid, publisher, snapshot) do
    case scope.agents[uid] do
      nil ->
        loop(conn, scope)

      agent ->
        key = %{agent_uid: uid, session_id: scope.session}

        valid =
          snapshot.agentUID == uid and snapshot.sessionID == scope.session and
            (snapshot.state != "active" or
               (publisher != agent.retired_driver and
                  publisher == Ankole.Sessions.driver_pid(key) and Activity.valid?(snapshot)))

        if valid do
          {snapshot, changed?} = merge_activity(agent.activity, snapshot)
          agent = monitor_driver(%{agent | activity: snapshot}, Ankole.Sessions.driver_pid(key))
          scope = put_in(scope.agents[uid], agent)
          if changed?, do: control(conn, scope, :activity, snapshot), else: loop(conn, scope)
        else
          loop(conn, scope)
        end
    end
  end

  defp driver_down(conn, scope, ref, pid) do
    case Enum.find(scope.agents, fn {_uid, agent} -> agent.monitor == ref end) do
      {uid, agent} ->
        snapshot = %{agent.activity | state: "unavailable", phase: nil, tools: []}
        agent = %{agent | activity: snapshot, monitor: nil, driver: nil, retired_driver: pid}
        control(conn, put_in(scope.agents[uid], agent), :activity, snapshot)

      nil ->
        loop(conn, scope)
    end
  end

  defp gateway_event(conn, scope, :response_started, gateway) do
    if snapshot_covers?(scope, gateway, :started) do
      loop(conn, scope)
    else
      {payload, scope} = response_payload(scope, gateway)
      agent = scope.agents[gateway.subject_uid]

      control(
        conn,
        scope,
        :started,
        Map.merge(payload, %{
          agentName: agent.name,
          turnStartedAt: DateTime.to_iso8601(DateTime.utc_now())
        })
      )
    end
  end

  defp gateway_event(conn, scope, event, %{payload: %{text: text}} = gateway)
       when event in [:output_text_delta, :reasoning_delta] and is_binary(text) do
    if snapshot_covers?(scope, gateway, :delta) do
      loop(conn, scope)
    else
      {payload, scope} = response_payload(scope, gateway)
      event = if event == :output_text_delta, do: :delta, else: :reasoning_delta
      key = {gateway.subject_uid, event, gateway.response_id}
      {payload, chunks} = Map.get(scope.buffers, key, {payload, []})

      scope = %{
        scope
        | buffers: Map.put(scope.buffers, key, {payload, [text | chunks]}),
          flush_at: scope.flush_at || now() + @flush_interval
      }

      loop(conn, scope)
    end
  end

  defp gateway_event(conn, scope, event, _gateway)
       when event in [:response_completed, :response_incomplete, :response_failed],
       do: committed(conn, scope)

  defp gateway_event(conn, scope, _event, _gateway), do: loop(conn, scope)

  defp response_payload(scope, gateway) do
    uid = gateway.subject_uid
    agent = scope.agents[uid]

    signal_ids =
      case agent.response do
        {id, ids} when id == gateway.response_id -> ids
        _ -> Ankole.Sessions.response_signal_ids(gateway)
      end

    scope = put_in(scope.agents[uid].response, {gateway.response_id, signal_ids})

    {%{
       conversationID: scope.id,
       agentUID: uid,
       sessionID: scope.session,
       responseID: gateway.response_id,
       signalIDs: signal_ids
     }, scope}
  end

  defp control(conn, scope, event, payload) do
    {buffered, scope} = flush(scope)
    write(conn, [buffered, frame(event, payload)], scope)
  end

  defp flush(scope) do
    frames =
      Enum.map(scope.buffers, fn {{_uid, event, _id}, {payload, chunks}} ->
        delta = chunks |> Enum.reverse() |> IO.iodata_to_binary()
        frame(event, Map.put(payload, :text, delta))
      end)

    {frames, %{scope | buffers: %{}, flush_at: nil}}
  end

  defp sync_agents(scope) do
    agents = Map.new(Native.room_agents(scope.id), &{&1.uid, &1})
    removed = Map.drop(scope.agents, Map.keys(agents))
    Enum.each(removed, fn {uid, agent} -> unsubscribe(uid, agent, scope.session) end)
    current = Map.take(scope.agents, Map.keys(agents))

    current =
      Enum.reduce(agents, current, fn {uid, principal}, current ->
        model =
          Ankole.AIGateway.list_active_conversations(
            subject_uid: uid,
            conversation_key: scope.session,
            limit: 1
          )
          |> List.first()

        existing = current[uid]

        if existing && existing.model == (model && model.id) do
          Map.put(current, uid, refresh_agent(existing, uid, scope.session))
        else
          if existing, do: unsubscribe(uid, existing, scope.session)
          :ok = SessionEvents.subscribe(uid, scope.session)
          if model, do: Events.subscribe(uid, model.id)
          {snapshot, pid} = Activity.current(%{agent_uid: uid, session_id: scope.session})

          agent = %{
            model: model && model.id,
            name: Ankole.Principals.display_name(principal),
            activity: snapshot,
            response: nil,
            snapshot_watermark: nil,
            monitor: nil,
            driver: nil,
            retired_driver: nil
          }

          Map.put(current, uid, monitor_driver(agent, pid))
        end
      end)

    %{
      scope
      | agents: current,
        buffers:
          Map.reject(scope.buffers, fn {{uid, _, _}, _} -> not Map.has_key?(current, uid) end)
    }
  end

  defp refresh_agent(agent, uid, session) do
    {snapshot, pid} = Activity.current(%{agent_uid: uid, session_id: session})
    {snapshot, _changed?} = merge_activity(agent.activity, snapshot, true)
    monitor_driver(%{agent | activity: snapshot}, pid)
  end

  defp activity_frames(scope),
    do: Enum.map(scope.agents, fn {_uid, agent} -> frame(:activity, agent.activity) end)

  defp snapshot_frames(scope), do: snapshot_frames(scope, Map.keys(scope.agents), false)

  defp snapshot_frames(scope, uids, started?) do
    Enum.map_reduce(uids, scope, fn uid, scope ->
      agent = scope.agents[uid]

      case Ankole.Sessions.Driver.display_snapshot(%{agent_uid: uid, session_id: scope.session}) do
        nil ->
          {[], scope}

        snapshot ->
          payload =
            Map.merge(snapshot, %{conversationID: scope.id, agentUID: uid, agentName: agent.name})

          agent = %{
            agent
            | response: {snapshot.responseID, snapshot.signalIDs},
              snapshot_watermark: {snapshot.responseID, snapshot.seq}
          }

          frames =
            if started?,
              do: [frame(:started, payload), frame(:snapshot, payload)],
              else: frame(:snapshot, payload)

          {frames, put_in(scope.agents[uid], agent)}
      end
    end)
  end

  defp snapshot_covers?(scope, gateway, kind) do
    case scope.agents[gateway.subject_uid].snapshot_watermark do
      {id, seq} when id == gateway.response_id ->
        kind == :started or is_nil(seq) or gateway.payload.seq <= seq

      _ ->
        false
    end
  end

  defp unsubscribe(uid, agent, session) do
    if agent.monitor, do: Process.demonitor(agent.monitor, [:flush])
    if agent.model, do: Events.unsubscribe(uid, agent.model)
    SessionEvents.unsubscribe(uid, session)
  end

  defp monitor_driver(%{driver: pid} = agent, pid), do: agent

  defp monitor_driver(agent, pid) do
    if agent.monitor, do: Process.demonitor(agent.monitor, [:flush])
    %{agent | driver: pid, monitor: if(is_pid(pid), do: Process.monitor(pid))}
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

  defp write(conn, data, scope) do
    if authorized?(conn, scope) do
      case chunk(conn, data) do
        {:ok, conn} -> loop(conn, scope)
        {:error, _reason} -> {conn, scope}
      end
    else
      case chunk(
             conn,
             frame(:access_revoked, %{conversationID: scope.id, reason: "access_revoked"})
           ) do
        {:ok, conn} -> {conn, scope}
        {:error, _reason} -> {conn, scope}
      end
    end
  end

  defp authorized?(conn, scope) do
    with %{"principal_uid" => uid} <- AnkoleWeb.Session.pod_session(conn),
         true <- uid == conn.assigns.current_principal_uid,
         {:ok, principal} <- Ankole.Principals.get_principal(uid),
         do: Native.visible_conversation?(%{scope.actor | principal: principal}, scope.id),
         else: (_ -> false)
  end

  defp frame(event, data),
    do: ["event: ", to_string(event), "\ndata: ", Ankole.JSON.encode!(data), "\n\n"]

  defp now, do: System.monotonic_time(:millisecond)
end
