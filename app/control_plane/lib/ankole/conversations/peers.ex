defmodule Ankole.Conversations.Peers do
  @moduledoc "Durable peer exchanges and their projections into the originating conversation."
  require Ash.Query
  alias Ankole.{Conversations, Principals, Repo, Signals}

  alias Ankole.Conversations.{
    Conversation,
    Message,
    Native,
    NativeRoom,
    PostResult,
    Queries,
    Route
  }

  alias Ankole.Sessions.Key

  @doc "Whether two ordinary replies return to the same Human request and origin."
  def same_task_reply?(
        %{producer: :kernel, type: "agent.peer_message", session_id: session, data: data} = first,
        %{producer: :kernel, type: "agent.peer_message", session_id: session, data: other} = next
      ) do
    is_binary(data["root_human_signal_id"]) and
      data["root_human_signal_id"] == other["root_human_signal_id"] and
      data["origin_session_id"] == session and other["origin_session_id"] == session and
      data["priority"] == false and other["priority"] == false and
      data["peer_hop_count"] == other["peer_hop_count"] and
      first.agent_uid == next.agent_uid and
      data["origin_reply_route"] == other["origin_reply_route"] and
      Principals.WorkAccess.fields(first) == Principals.WorkAccess.fields(next)
  end

  def same_task_reply?(_, _), do: false

  def exchanges(origin_ids) do
    Conversation
    |> Ash.Query.filter(
      native_access_scope == :agent_peer and origin_conversation_id in ^origin_ids
    )
    |> Ankole.Ash.read!()
  end

  def exchange(id) do
    case Conversations.get_conversation!(id) do
      %Conversation{native_access_scope: :agent_peer} = peer -> peer
      _ -> nil
    end
  end

  def callback_origin(source, binding_id, origin_id) do
    with %{origin_conversation_id: ^origin_id, peer_sender_uid: sender} <-
           source && exchange(source.conversation_id),
         %{"binding_id" => ^binding_id} <- source.data["origin_reply_route"],
         session when is_binary(session) <- source.data["origin_session_id"] do
      {sender, session}
    else
      _ -> nil
    end
  end

  def session_keys(%{agent_uid: uid, session_id: session} = source) do
    case Key.parse(session) do
      {:conversation, id} ->
        case exchange(id) do
          %{origin_conversation_id: origin, peer_sender_uid: sender} when not is_nil(origin) ->
            [{uid, session}, {sender, origin_session(source, origin)}]

          _ ->
            [{uid, session}]
        end

      _ ->
        [{uid, session}]
    end
  end

  defp origin_session(source, origin) do
    event = Map.get(source, :event, source)
    get_in(peer_context(event), ["origin_session_id"]) || Key.conversation(origin)
  end

  defp peer_context(event) do
    data = Map.get(event, :data, %{})

    if data["origin_session_id"] do
      data
    else
      case Route.authorization_source(event) do
        nil -> data
        source -> Map.merge(peer_context(source), data)
      end
    end
  end

  def lock_reply_rooms(run) do
    case Key.parse(run.session_id) do
      {:conversation, id} ->
        case exchange(id) do
          nil -> :ok
          peer -> lock_rooms([peer.origin_conversation_id, id])
        end

      _ ->
        :ok
    end
  end

  def send_from_job(%Ankole.Sessions.JobTurnRef{} = ref, args, call_id)
      when is_binary(call_id) and call_id != "" do
    declaration = hd(Ankole.Sessions.Tools.Peers.declarations())

    with {:ok, args} <- Ankole.Sessions.ToolArguments.validate(declaration["parameters"], args) do
      Repo.transact_top_level(
        fn ->
          event = Signals.get_signal!(ref.signal_id)

          run = %{
            agent_uid: ref.agent_uid,
            session_id: ref.session_id,
            signal_id: ref.signal_id,
            event: event,
            peer_call_id: ref.signal_id <> ":" <> call_id
          }

          with {:ok, keys, commit} <- prepare_send(run, args),
               :ok <- Ankole.AuthZ.authorize_turn_in_tx({ref, ref.agent_uid}),
               :ok <- Ankole.Sessions.Queue.lock_sessions_in_tx(keys),
               {:ok, result, publications} <- commit.() do
            {:ok, %{result: result, publications: publications}}
          end
        end,
        after_commit: fn result -> Enum.each(result.publications, & &1.()) end
      )
      |> case do
        {:ok, result} -> {:ok, Ankole.Sessions.ToolResult.encode(result.result)}
        error -> error
      end
    end
  end

  def send_from_job(_, _, _), do: {:error, :invalid_request}

  def prepare_send(run, args) do
    target = args["target_agent_uid"]

    event =
      case List.last(Map.get(run, :steer_event_ids, [])) do
        nil -> run.event
        id -> Signals.get_signal!(id)
      end

    run = %{run | signal_id: event.id, event: %{event | data: peer_context(event)}}

    with true <- Ankole.Agents.MessagingPolicy.allow_peer_send?(run.agent_uid, target, run.event),
         {:ok, origin, owner_session, route} <- origin(run),
         true <- (run.event.data["peer_hop_count"] || 0) < 6,
         :ok <- Ankole.Pod.lock_tree_in_tx(),
         {:ok, _} <-
           Principals.lock_principals_in_tx([run.event.human_uid, run.agent_uid, target]),
         {:ok, pages} <- page_access(run, target, args["page_ids"] || []) do
      peer =
        Enum.find(
          exchanges([origin.id]),
          &(&1.peer_sender_uid == run.agent_uid and &1.peer_target_uid == target)
        )

      id = if peer, do: peer.id, else: Ankole.Ecto.UUIDv7.autogenerate()

      keys = [
        {run.agent_uid, run.session_id},
        {run.agent_uid, owner_session},
        {target, Key.conversation(id)}
      ]

      {:ok, keys, fn -> send_in_tx(run, args, origin, id, owner_session, route, pages) end}
    else
      false -> {:error, :peer_send_not_allowed_or_hop_limit}
      error -> error
    end
  end

  defp origin(run) do
    with {:ok, source} <- origin_route(run),
         id when is_binary(id) <- source.reply_route["conversation_id"],
         %Conversation{} = origin <- Conversations.get_conversation!(id),
         true <- origin.native_access_scope != :agent_peer do
      route =
        Map.put_new(source.reply_route, "binding_id", get_in(source, [:source, :binding_id]))

      {:ok, origin, source.owner_session_id, route}
    else
      _ -> {:error, :origin_conversation_required}
    end
  end

  defp origin_route(%{event: %{type: "cron.fire"} = event}) do
    with delivery when is_map(delivery) <-
           Ankole.Signals.Signal.scheduled_delivery_snapshot(event),
         {:ok, [target]} <- Ankole.Schedule.Delivery.targets(delivery, event.reply_binding_name),
         id when is_binary(id) <- target["conversation_id"],
         %{kind: :native} <- Conversations.get_conversation!(id) do
      {:ok, %{owner_session_id: Key.conversation(id), reply_route: target}}
    else
      _ -> {:error, :origin_conversation_required}
    end
  end

  defp origin_route(run), do: Route.long_lived_source(run)

  defp page_access(run, uid, ids) do
    with {:ok, target} <- Principals.get_principal(uid),
         {:ok, sender} <- Principals.get_principal(run.agent_uid) do
      missing =
        Enum.reject(
          ids,
          &match?(
            {:ok, _},
            Ankole.Pod.authorize_node(Ankole.AuthZ.Actor.new(target), &1, "node_view")
          )
        )

      if missing == [] do
        {:ok, ids}
      else
        {:error,
         %{
           "error" => "target_missing_page_access",
           "missing_page_ids" => missing,
           "caller_can_share" =>
             Enum.all?(
               missing,
               &match?(
                 {:ok, _},
                 Ankole.Pod.authorize_node(Ankole.AuthZ.Actor.new(sender), &1, "node_manage")
               )
             )
         }}
      end
    end
  end

  defp send_in_tx(run, args, origin, id, owner_session, route, pages) do
    target = args["target_agent_uid"]
    now = DateTime.utc_now(:microsecond)

    with {:ok, _} <-
           Ankole.Ash.create(Conversation, :ensure_native, %{
             id: id,
             title: String.slice(args["message"], 0, 80),
             created_by: run.event.human_uid,
             room_mode: :dm,
             native_access_scope: :agent_peer,
             last_activity_at: now,
             origin_conversation_id: origin.id,
             peer_sender_uid: run.agent_uid,
             peer_target_uid: target
           }),
         :ok <- lock_rooms([origin.id, id]),
         {:ok, _} <- NativeRoom.join(id, run.agent_uid, :agent),
         {:ok, _} <- NativeRoom.join(id, target, :agent),
         peer = exchange(id),
         message_id = Map.get(run, :peer_call_id) || Ankole.Ecto.UUIDv7.autogenerate(),
         data = %{
           "text" => args["message"],
           "exchange_id" => id,
           "page_ids" => pages,
           "origin_signal_id" => run.signal_id,
           "origin_session_id" => owner_session,
           "origin_reply_route" => route,
           "root_human_signal_id" => run.event.data["root_human_signal_id"] || run.signal_id,
           "peer_hop_count" => (run.event.data["peer_hop_count"] || 0) + 1,
           "priority" => args["priority"] == true,
           "silence_allowed" => true
         },
         {:ok, signal} <- accept(peer, run.event, message_id, data),
         {:ok, _} <-
           record(peer, run.event, args["message"], "request:" <> message_id, %{}, pages),
         {:ok, card} <-
           outbound(
             origin,
             run.event,
             args["message"],
             "peer:" <> message_id,
             %{"agent_peer_outbound" => %{"exchange_id" => id, "agent_uid" => target}},
             pages
           ) do
      {:ok,
       Ankole.Sessions.Tools.result(%{
         status: "delivered",
         exchange_id: id,
         guidance:
           "The colleague owns this task and will ask any missing business questions directly in the original conversation through clarify. Do not ask those questions yourself or wait for its reply. Finish any independent work, then end this turn; the result will wake you here."
       }),
       [
         fn ->
           Signals.publish_committed(signal)
           if card, do: Conversations.Events.publish_message(card.conversation_id)
         end
       ]}
    end
  end

  defp outbound(%{kind: :external}, _event, _text, _key, _rich, _pages), do: {:ok, nil}

  defp outbound(origin, event, text, key, rich, pages),
    do: record(origin, event, text, key, rich, pages)

  defp accept(peer, source, id, data) do
    Signals.accept_in_tx(%{
      producer: :kernel,
      source: "control-plane://agent-peer",
      id: id,
      type: "agent.peer_message",
      target: %{agent_uid: peer.peer_target_uid, conversation_id: peer.id},
      sender: source.agent_uid,
      authorization: Principals.WorkAccess.fields(source),
      data: data
    })
  end

  def lock_rooms(ids) do
    Enum.each(
      ids |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort(),
      &Queries.lock_conversation/1
    )

    :ok
  end

  def record(conversation, event, text, delivery_key, rich, pages \\ []) do
    case Message
         |> Ash.Query.filter(
           conversation_id == ^conversation.id and signal_id == ^event.id and
             delivery_key == ^delivery_key
         )
         |> Ankole.Ash.read_one!() do
      nil -> record_new(conversation, event, text, delivery_key, rich, pages)
      message -> {:ok, message}
    end
  end

  defp record_new(conversation, event, text, delivery_key, rich, pages) do
    notifiable? = is_map(rich["clarify"]) or is_map(rich["action_card"])

    with {:ok, seq} <- Queries.next_sequence_in_tx(conversation, notifiable?),
         {:ok, message} <-
           Ankole.Ash.create(Message, :record, %{
             id: Ankole.Ecto.UUIDv7.autogenerate(),
             conversation_id: conversation.id,
             seq: seq,
             author_type: :agent,
             author_uid: event.agent_uid,
             kind: :message,
             origin: :native,
             session_id: event.session_id,
             signal_id: event.id,
             delivery_key: delivery_key,
             text: text,
             rich_content: rich,
             links: Enum.map(pages, &%{"kind" => "page", "id" => &1}),
             created_at: DateTime.utc_now(:microsecond)
           }),
         :ok <-
           touch_notifiable(
             conversation,
             notifiable? or conversation.native_access_scope == :agent_peer,
             message.created_at
           ) do
      {:ok, message}
    end
  end

  defp touch_notifiable(conversation, true, now) do
    with {:ok, _} <- Ankole.Ash.update(conversation, :touch, %{last_activity_at: now}), do: :ok
  end

  defp touch_notifiable(_, _, _), do: :ok

  def project_in_tx(event, posted, statement) do
    case event.conversation_id && exchange(event.conversation_id) do
      %{origin_conversation_id: origin} = peer when not is_nil(origin) ->
        project_reply(peer, %{event | data: peer_context(event)}, posted, statement)

      _ ->
        {:ok, posted}
    end
  end

  defp project_reply(peer, event, posted, statement) do
    origin = Conversations.get_conversation!(peer.origin_conversation_id)

    question? =
      is_map(statement.completion[:clarify_prompt]) or
        is_map(statement.completion[:action_card_prompt])

    with {:ok, projection} <- project_messages(origin, peer, event, posted.messages, statement),
         {:ok, signals} <-
           if(question?,
             do: {:ok, []},
             else: wake_origin(peer, event, List.last(posted.messages))
           ) do
      {:ok, PostResult.merge(posted, %{projection | signals: signals})}
    end
  end

  defp project_messages(%{kind: :external}, _peer, event, _messages, statement) do
    if statement.completion[:clarify_prompt] || statement.completion[:action_card_prompt] do
      route = event.data["origin_reply_route"]
      sender = exchange(event.conversation_id).peer_sender_uid

      with {:ok, target} <- Conversations.Target.for_delivery_in_tx(sender, route),
           do:
             Conversations.Delivery.Posting.post_in_tx(target, %{
               statement
               | signal: %{event | provider_message_id: route["provider_message_id"]}
             })
    else
      {:ok, %PostResult{}}
    end
  end

  defp project_messages(origin, peer, event, messages, _statement) do
    Enum.reduce_while(messages, {:ok, %PostResult{}}, fn message, {:ok, result} ->
      rich =
        if is_map(message.rich_content["clarify"]) or is_map(message.rich_content["action_card"]),
          do: Map.put(message.rich_content, "peer_agent_uid", event.agent_uid),
          else: %{
            "agent_peer_inbound" => %{"exchange_id" => peer.id, "agent_uid" => event.agent_uid}
          }

      pages = for %{"kind" => "page", "id" => id} <- message.links, do: id

      case record(origin, event, message.text, "peer:" <> message.id, rich, pages) do
        {:ok, card} -> {:cont, {:ok, PostResult.merge(result, %PostResult{messages: [card]})}}
        error -> {:halt, error}
      end
    end)
  end

  defp wake_origin(_peer, _event, nil), do: {:ok, []}

  defp wake_origin(peer, event, message) do
    hops = min((event.data["peer_hop_count"] || 0) + 1, 6)

    data =
      event.data
      |> Map.put("text", message.text)
      |> Map.put("exchange_id", peer.id)
      |> Map.put("peer_hop_count", hops)
      |> Map.put("silence_allowed", hops < 6)
      |> Map.put("priority", false)

    with {:ok, signal} <-
           Signals.accept_in_tx(%{
             producer: :kernel,
             source: "control-plane://agent-peer",
             id: message.id,
             type: "agent.peer_message",
             target: %{
               agent_uid: peer.peer_sender_uid,
               session_id: event.data["origin_session_id"]
             },
             reply_route: event.data["origin_reply_route"],
             sender: event.agent_uid,
             authorization: Principals.WorkAccess.fields(event),
             data: data
           }),
         do: {:ok, [signal]}
  end

  def visible(actor, origin_id, id) do
    with {:ok, _} <- Native.visible_native_conversation(actor, origin_id),
         %{origin_conversation_id: ^origin_id} = peer <- exchange(id),
         do: {:ok, peer},
         else: (_ -> {:error, :conversation_not_found})
  end

  def answer_in_tx(actor, origin_id, source, attrs) do
    origin = Conversations.get_conversation!(origin_id)
    peer = exchange(source.conversation_id)
    uid = Ankole.AuthZ.Actor.uid(actor)
    id = Ankole.Ecto.UUIDv7.autogenerate()

    with {:ok, text, attachments} <-
           Native.human_content(actor, origin_id, attrs.message_id, attrs),
         {:ok, _, _} <-
           Native.append_human_message_in_tx(
             origin,
             uid,
             attrs.message_id,
             text,
             attachments,
             attrs
           ),
         {:ok, message, _} <-
           Native.append_human_message_in_tx(peer, uid, id, text, attachments, attrs),
         {:ok, event} <-
           Signals.accept_in_tx(%{
             producer: :kernel,
             source: Key.conversation(peer.id),
             id: id,
             type: "conversation.message.addressed",
             sender: uid,
             message_id: message.id,
             target: %{agent_uid: source.agent_uid, conversation_id: peer.id},
             data:
               source.data
               |> Map.delete("interaction_answer")
               |> Map.merge(%{
                 "text" => attrs.text,
                 "peer_hop_count" => 0,
                 "root_human_signal_id" => id,
                 "answered_interaction_id" => attrs.answered_interaction_id
               })
               |> Ankole.Attrs.maybe_put("interaction_answer", attrs[:interaction_answer])
           }) do
      {:ok,
       %{
         id: origin_id,
         events: [event],
         session_key: event,
         session_keys: [event],
         publications: [{origin_id, :message}, {peer.id, :message}]
       }}
    end
  end

  def answer_external_in_tx(source, fact, resolution) do
    peer = exchange(source.conversation_id)
    uid = fact.sender_key
    text = resolution["answer"]["value"]
    id = Ankole.Ecto.UUIDv7.autogenerate()

    with :ok <- lock_rooms([peer.id]),
         {:ok, message, _} <- Native.append_human_message_in_tx(peer, uid, id, text, [], %{}),
         {:ok, signal} <-
           Signals.accept_in_tx(%{
             producer: :kernel,
             source: "control-plane://agent-peer-answer",
             id: fact.source_event_id,
             type: "conversation.message.addressed",
             sender: uid,
             message_id: message.id,
             target: %{agent_uid: peer.peer_target_uid, conversation_id: peer.id},
             data:
               source.data
               |> Map.delete("interaction_answer")
               |> Map.merge(%{
                 "text" => text,
                 "peer_hop_count" => 0,
                 "root_human_signal_id" => id,
                 "answered_interaction_id" => resolution["interaction_id"]
               })
               |> Ankole.Attrs.maybe_put(
                 "interaction_answer",
                 if(resolution["answer"]["kind"] == "form", do: resolution["answer"])
               )
           }) do
      {:ok, signal}
    end
  end

  def detail(actor, origin_id, id, cursor) do
    with {:ok, peer} <- visible(actor, origin_id, id) do
      rows =
        Message
        |> Ash.Query.filter(conversation_id == ^id and seq > ^(cursor || 0) and not withdrawn)
        |> Ash.Query.sort(seq: :asc)
        |> Ash.Query.limit(51)
        |> Ankole.Ash.read!()

      key = %{agent_uid: peer.peer_target_uid, session_id: Key.conversation(id)}
      {activity, _} = Ankole.Sessions.Activity.current(key)
      snapshot = Ankole.Sessions.Driver.display_snapshot(key)

      pending =
        Conversations.latest_native_questions([id])
        |> Conversations.Delivery.Interactions.native_interactions()
        |> Enum.any?(fn {_, state} -> state["state"] == "pending" end)

      status =
        Ankole.Sessions.statuses([{key.agent_uid, key.session_id}])[
          {key.agent_uid, key.session_id}
        ]

      messages = Enum.take(rows, 50)

      {:ok,
       %{
         id: id,
         agentUID: peer.peer_target_uid,
         status: if(pending, do: "waiting_choice", else: to_string(status.state)),
         messages:
           Enum.map(
             messages,
             &%{
               id: &1.id,
               seq: &1.seq,
               authorUID: &1.author_uid,
               text: &1.text,
               execution: Map.drop(&1.rich_content["execution"] || %{}, ["thinking_summary"])
             }
           ),
         nextCursor: if(length(rows) > 50, do: List.last(messages).seq),
         activity: activity,
         text: if(snapshot, do: snapshot.text, else: "")
       }}
    end
  end

  def stop(actor, origin_id, id) do
    Repo.transact_top_level(
      fn ->
        with :ok <- Ankole.Pod.lock_tree_in_tx(),
             {:ok, peer} <- visible(actor, origin_id, id),
             {:ok, _} <-
               Principals.lock_principals_in_tx([
                 Ankole.AuthZ.Actor.uid(actor),
                 peer.peer_sender_uid,
                 peer.peer_target_uid
               ]),
             :ok <-
               Ankole.Sessions.Queue.lock_sessions_in_tx([
                 {peer.peer_sender_uid, Key.conversation(origin_id)},
                 {peer.peer_target_uid, Key.conversation(id)}
               ]),
             :ok <- Native.check_human_in_tx(actor),
             {:ok, signal} <- stop_in_tx(peer, Ankole.AuthZ.Actor.uid(actor)) do
          {:ok, signal}
        end
      end,
      after_commit: &Signals.publish_committed/1
    )
  end

  def stop_in_tx(peer, human_uid) do
    with {:ok, [signal]} <- stop_all_in_tx([peer], human_uid), do: {:ok, signal}
  end

  def stop_all_in_tx([], _human_uid), do: {:ok, []}

  def stop_all_in_tx(peers, human_uid) do
    now = DateTime.utc_now(:microsecond)

    attrs =
      Enum.map(peers, fn peer ->
        %{
          producer: :kernel,
          source: "control-plane://agent-peer-stop",
          id: Ankole.Ecto.UUIDv7.autogenerate(),
          type: "command.stop",
          sender: human_uid,
          target: %{agent_uid: peer.peer_target_uid, conversation_id: peer.id},
          data: %{}
        }
      end)

    stop_ids = MapSet.new(attrs, & &1.id)
    sessions = Enum.map(peers, &Key.conversation(&1.id))

    with {:ok, signals} <- Signals.accept_all_in_tx(attrs),
         locked =
           Signals.lock_signals_in_tx(
             session_id: [in: sessions],
             status: :queued,
             last_attempt_at: [is_nil: true]
           ),
         {stops, queued_inputs} = Enum.split_with(locked, &MapSet.member?(stop_ids, &1.id)),
         {:ok, _} <-
           Ankole.Attrs.collect_results(
             Enum.map(queued_inputs, &Ankole.Sessions.Queue.mark_event_completed_in_tx(&1, now))
           ),
         {:ok, settled} <-
           Ankole.Attrs.collect_results(Enum.map(stops, &settle_idle_stop_in_tx(&1, now))) do
      by_id = Map.new(settled, &{&1.id, &1})
      {:ok, Enum.map(signals, &Map.get(by_id, &1.id, &1))}
    end
  end

  defp settle_idle_stop_in_tx(signal, now) do
    if Ankole.Sessions.Queue.oldest_started(signal.agent_uid, signal.session_id),
      do: {:ok, signal},
      else: Ankole.Sessions.Queue.complete_command_event_in_tx(signal, completed_at: now)
  end
end
