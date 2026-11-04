defmodule Ankole.Conversations.PeersTest do
  use Ankole.DataCase, async: false
  import Ankole.AIGatewayCase, only: [start_response_run: 1]
  import Ankole.PrincipalsFixtures, only: [human_fixture: 0, actor_fixture: 1]
  alias Ankole.{Conversations, Signals}
  alias Ankole.Conversations.Peers
  alias Ankole.Sessions.{Queue, Presentation, Admission, Model, Run, Tools}
  alias Ankole.Conversations.Delivery.{Interactions, PreviewStates}
  alias Ankole.AIGateway.ResponseCommit

  setup do
    human = human_fixture().principal

    assistant =
      Ankole.SessionsCase.agent_fixture(%{
        type: :personal_assistant,
        owner_principal_uid: human.uid
      }).principal

    colleague = Ankole.SessionsCase.agent_fixture(%{owner_principal_uid: human.uid}).principal
    Ankole.ConversationsFixtures.grant_chat(human.uid, colleague.uid)
    %{human: human, actor: actor_fixture(human), assistant: assistant, colleague: colleague}
  end

  test "one colleague DM survives repeat entry and adding people creates a separate group", ctx do
    first = room(ctx.actor, ctx.colleague.uid)
    second = room(ctx.actor, ctx.colleague.uid)
    assert first.conversation.id == second.conversation.id
    assert second.conversation.sequence_high_water == 2
    other = human_fixture().principal

    assert {:error, :forbidden_room_operation} =
             Conversations.manage_participants(ctx.actor, first.conversation.id, %{
               add_uids: [other.uid]
             })

    group =
      room(ctx.actor, ctx.colleague.uid, %{room_mode: :group, participant_uids: [other.uid]})

    refute group.conversation.id == first.conversation.id
    assert Conversations.get_conversation!(first.conversation.id).room_mode == :dm
  end

  test "assistant mentions stay metadata and peer cards do not advance unread activity", ctx do
    origin =
      room(ctx.actor, ctx.assistant.uid, %{mentions: [%{type: "agent", uid: ctx.colleague.uid}]})

    assert Enum.map(origin.agents, & &1.uid) == [ctx.assistant.uid]
    [event] = Signals.list_signals!(query: [filter: [conversation_id: origin.conversation.id]])
    exchange_id = send_peer(ctx, event)
    peer = Peers.exchange(exchange_id)
    assert peer.peer_target_uid == ctx.colleague.uid
    changed = Conversations.get_conversation!(origin.conversation.id)
    assert changed.last_notifiable_seq == 1
    assert changed.sequence_high_water == 2
    assert changed.last_activity_at == origin.conversation.last_activity_at

    assert Enum.map(Conversations.list(ctx.actor), & &1.conversation.id) == [
             origin.conversation.id
           ]

    assert {:error, :conversation_not_found} = Conversations.get(ctx.actor, peer.id)
    assert {:ok, _} = Peers.detail(ctx.actor, origin.conversation.id, peer.id, nil)
    assert send_peer(ctx, event) == peer.id
  end

  test "unbound historical DMs keep their own identity beside the canonical colleague DM", ctx do
    historical_id = Ecto.UUID.generate()

    assert {:ok, _} =
             Repo.transact_top_level(fn ->
               {:ok, conversation} =
                 Ankole.Ash.create(Conversations.Conversation, :ensure_native, %{
                   id: historical_id,
                   title: "Last year's contract review",
                   created_by: ctx.human.uid,
                   last_activity_at: DateTime.utc_now(:microsecond)
                 })

               {:ok, _} = Conversations.NativeRoom.join(historical_id, ctx.human.uid, :owner)
               {:ok, _} = Conversations.NativeRoom.join(historical_id, ctx.colleague.uid, :agent)

               with {:ok, message, _} <-
                      Conversations.Native.append_human_message_in_tx(
                        conversation,
                        ctx.human.uid,
                        Ecto.UUID.generate(),
                        "The previous contract has a different approval window.",
                        [],
                        %{}
                      ),
                    do: {:ok, message}
             end)

    current = room(ctx.actor, ctx.colleague.uid)

    rows =
      ctx.actor |> Conversations.list_rooms([]) |> Ankole.Pod.Chat.Presentation.conversations()

    historical = Enum.find(rows, &(&1.id == historical_id))
    canonical = Enum.find(rows, &(&1.id == current.conversation.id))

    assert historical.roomMode == :dm
    assert historical.conversationKind == :group
    assert historical.title == "Last year's contract review"
    assert canonical.conversationKind == :colleague_dm
    assert Conversations.direct_conversations(ctx.human.uid)[ctx.colleague.uid] == canonical.id
    assert {:ok, detail} = Conversations.get(ctx.actor, historical_id)
    assert Enum.any?(detail.messages, &String.contains?(&1.text, "previous contract"))
  end

  for hops <- [2, 6] do
    test "an applied Human follow-up starts a fresh delegation chain inside a peer-result turn at hop #{hops}",
         ctx do
      origin = room(ctx.actor, ctx.assistant.uid)
      [source] = Signals.list_signals!(query: [filter: [conversation_id: origin.conversation.id]])
      id = send_peer(ctx, source)
      [peer_event] = Signals.list_signals!(query: [filter: [conversation_id: id]])

      peer_event = %{
        peer_event
        | data: Map.put(peer_event.data, "peer_hop_count", unquote(hops) - 1)
      }

      assert {:ok, %{signals: [wake]}} =
               Repo.transact_top_level(fn ->
                 :ok = Queue.lock_sessions_in_tx(Peers.session_keys(peer_event))

                 Presentation.post_in_tx(peer_event, %Conversations.Statement{
                   signal: peer_event,
                   outcome: :replied,
                   completion: %{final_text: "Review needs a new instruction", attachments: []}
                 })
               end)

      assert wake.data["peer_hop_count"] == unquote(hops)
      assert {:ok, run} = Admission.admit(wake, wake)
      assert {:ok, {:preparing, run}} = Model.prepare(run)
      message_id = Ecto.UUID.generate()

      assert {:ok, _} =
               Conversations.post(ctx.actor, origin.conversation.id, %{
                 message_id: message_id,
                 text: "Ask legal to review the revised payment terms."
               })

      [followup] = Signals.list_signals!(query: [filter: [message_id: message_id]])

      run = %{run | pending_event_ids: [followup.id]}

      if unquote(hops) == 6 do
        assert {:error, :peer_send_not_allowed_or_hop_limit} =
                 Peers.prepare_send(run, %{
                   "target_agent_uid" => ctx.colleague.uid,
                   "message" => "Continue the old review"
                 })
      else
        silent = %{run | outcome: :loop_finished, model_response: %{content: []}}
        assert Ankole.Sessions.Main.repair(silent, "") == nil
        assert {:finalize, %{outcome: :silent}} = Ankole.Sessions.Main.finish(silent)
      end

      assert {:ok, [injected], run} =
               Run.inject_pending(run, fn _ -> true end)

      assert injected.id == followup.id
      assert run.signal_id == wake.id

      empty = %{run | outcome: :loop_finished, model_response: %{content: []}}
      assert {_repair, ^empty} = Ankole.Sessions.Main.repair(empty, "")
      assert {:finalize, %{outcome: :loop_finished}} = Ankole.Sessions.Main.finish(empty)

      assert {:ok, {result, _}} =
               Repo.transact_top_level(fn ->
                 with {:ok, keys, commit} <-
                        Peers.prepare_send(run, %{
                          "target_agent_uid" => ctx.colleague.uid,
                          "message" => "Review the revised payment terms"
                        }),
                      :ok <- Queue.lock_sessions_in_tx(keys),
                      {:ok, result, publications} <- commit.(),
                      do: {:ok, {result, publications}}
               end)

      assert result.details.exchange_id == id

      delegated =
        Signals.list_signals!(
          query: [filter: [conversation_id: id], sort: [queue_sequence: :desc]]
        )
        |> hd()

      assert delegated.data["peer_hop_count"] == 1
      assert delegated.data["root_human_signal_id"] == followup.id
      assert delegated.data["origin_signal_id"] == followup.id
    end
  end

  for hops <- [1, 6] do
    test "peer reply at hop #{hops} returns to the origin under the colleague's own authority",
         ctx do
      origin = room(ctx.actor, ctx.assistant.uid)
      [event] = Signals.list_signals!(query: [filter: [conversation_id: origin.conversation.id]])
      id = send_peer(ctx, event)
      [peer_event] = Signals.list_signals!(query: [filter: [conversation_id: id]])
      peer_event = %{peer_event | data: Map.put(peer_event.data, "peer_hop_count", unquote(hops))}
      assert peer_event.human_uid == ctx.human.uid
      assert peer_event.agent_uid == ctx.colleague.uid

      assert {:ok, posted} =
               Repo.transact_top_level(fn ->
                 :ok = Queue.lock_sessions_in_tx(Peers.session_keys(peer_event))

                 Presentation.post_in_tx(peer_event, %Conversations.Statement{
                   signal: peer_event,
                   outcome: :replied,
                   completion: %{final_text: "Review complete", attachments: []}
                 })
               end)

      assert length(posted.signals) == 1
      [wake] = posted.signals
      assert wake.agent_uid == ctx.assistant.uid
      assert wake.conversation_id == origin.conversation.id
      assert wake.type == "agent.peer_message"
      assert wake.data["peer_hop_count"] == min(unquote(hops) + 1, 6)

      if unquote(hops) == 6 do
        assert {:error, :peer_send_not_allowed_or_hop_limit} =
                 Peers.prepare_send(
                   %{
                     agent_uid: ctx.assistant.uid,
                     session_id: wake.session_id,
                     signal_id: wake.id,
                     event: wake
                   },
                   %{"target_agent_uid" => ctx.colleague.uid, "message" => "Continue"}
                 )
      end

      assert Conversations.get_conversation!(origin.conversation.id).last_notifiable_seq == 1
      assert Enum.any?(posted.messages, &(&1.rich_content["agent_peer_inbound"] != nil))
    end
  end

  test "recall connects private work to the same human DM but excludes group audiences", ctx do
    origin = room(ctx.actor, ctx.assistant.uid)
    [event] = Signals.list_signals!(query: [filter: [conversation_id: origin.conversation.id]])
    id = send_peer(ctx, event)
    dm = room(ctx.actor, ctx.colleague.uid)
    [dm_event] = Signals.list_signals!(query: [filter: [conversation_id: dm.conversation.id]])
    run = %{agent_uid: ctx.colleague.uid, event: dm_event}
    assert {:ok, %{messages: [_]}} = Conversations.recall_related_context(run, id, nil)

    assert {:ok, result} = Tools.RelatedContext.execute(run, %{}, %{"ref_id" => id})
    assert %{"ref_id" => ^id, "messages" => [message]} = Ankole.JSON.decode!(result.output)
    assert {:ok, _, 0} = DateTime.from_iso8601(message["created_at"])
    assert message["text"] == "Review the contract"

    other = human_fixture().principal

    group =
      room(ctx.actor, ctx.colleague.uid, %{room_mode: :group, participant_uids: [other.uid]})

    [group_event] =
      Signals.list_signals!(query: [filter: [conversation_id: group.conversation.id]])

    assert {:error, :related_context_unavailable} =
             Conversations.recall_related_context(%{run | event: group_event}, id, nil)
  end

  test "page preflight fails before sending and incremental sharing preserves collaborators",
       ctx do
    assert {:ok, page} = Ankole.Pod.Pages.create(ctx.actor, %{title: "Contract"})
    other = human_fixture().principal

    assert {:ok, _} =
             Ankole.Pod.Pages.update_sharing(ctx.actor, page.id, %{
               upserts: [%{principal_uid: other.uid, role: "view", target_scope: "self"}]
             })

    origin = room(ctx.actor, ctx.assistant.uid)
    [event] = Signals.list_signals!(query: [filter: [conversation_id: origin.conversation.id]])
    run = run(ctx, event)

    assert {:error, %{"error" => "target_missing_page_access", "caller_can_share" => true}} =
             Repo.transact_top_level(fn ->
               Peers.prepare_send(run, %{
                 "target_agent_uid" => ctx.colleague.uid,
                 "message" => "Review",
                 "page_ids" => [page.id]
               })
             end)

    assert {:ok, _} =
             Ankole.Pod.Pages.update_sharing(ctx.actor, page.id, %{
               upserts: [%{principal_uid: ctx.colleague.uid, role: "view", target_scope: "self"}]
             })

    assert {:ok, _} = Ankole.Pod.authorize_node(actor_fixture(other), page.id, "node_view")
    peer_id = send_peer(ctx, event, [page.id])
    dm = room(ctx.actor, ctx.colleague.uid)
    [dm_event] = Signals.list_signals!(query: [filter: [conversation_id: dm.conversation.id]])
    recall_run = %{agent_uid: ctx.colleague.uid, event: dm_event}

    assert Enum.any?(
             Ankole.Conversations.RelatedContext.index(recall_run),
             &(&1.ref_id == peer_id and &1.page_ids == [page.id])
           )

    assert {:ok, _} = Conversations.recall_related_context(recall_run, peer_id, nil)

    assert {:ok, _} =
             Ankole.Pod.Pages.update_sharing(ctx.actor, page.id, %{
               removes: [%{principal_uid: ctx.colleague.uid, target_scope: "self"}]
             })

    assert {:error, :related_context_unavailable} =
             Conversations.recall_related_context(recall_run, peer_id, nil)
  end

  test "a busy colleague remembers the requester's work after serving other people", ctx do
    origin = room(ctx.actor, ctx.assistant.uid)
    [event] = Signals.list_signals!(query: [filter: [conversation_id: origin.conversation.id]])
    peer_id = send_peer(ctx, event)
    other = human_fixture().principal
    Ankole.ConversationsFixtures.grant_chat(other.uid, ctx.colleague.uid)

    for _ <- 1..101 do
      room(actor_fixture(other), ctx.colleague.uid, %{room_mode: :group})
    end

    dm = room(ctx.actor, ctx.colleague.uid)
    [dm_event] = Signals.list_signals!(query: [filter: [conversation_id: dm.conversation.id]])
    run = %{agent_uid: ctx.colleague.uid, event: dm_event}

    assert Enum.map(Ankole.Conversations.RelatedContext.index(run), & &1.ref_id) == [peer_id]
    assert Conversations.related_context_index(run) =~ peer_id
    assert {:ok, %{messages: [message]}} = Conversations.recall_related_context(run, peer_id, nil)
    assert message.text == "Review the contract"
  end

  test "peer Clarify is answered in place without waking the assistant, and answers only once",
       ctx do
    origin = room(ctx.actor, ctx.assistant.uid)
    [event] = Signals.list_signals!(query: [filter: [conversation_id: origin.conversation.id]])
    id = send_peer(ctx, event)
    [peer_event] = Signals.list_signals!(query: [filter: [conversation_id: id]])
    card = clarify(peer_event)
    assert card.conversation_id == origin.conversation.id
    assert card.rich_content["peer_agent_uid"] == ctx.colleague.uid
    interaction = card.rich_content["clarify"]["interaction_id"]

    assert {:ok, changed} =
             Conversations.post(ctx.actor, origin.conversation.id, %{
               message_id: Ecto.UUID.generate(),
               text: "Meanwhile, summarize my calendar"
             })

    assert Enum.any?(
             Ankole.Pod.Chat.Presentation.detail(changed).pendingInteractions,
             &(&1["interaction_id"] == interaction)
           )

    assert {:ok, _} =
             Interactions.answer_native(ctx.actor, origin.conversation.id, interaction, %{
               choice_id: "choice-1"
             })

    assert {:error, :interaction_not_pending} =
             Interactions.answer_native(ctx.actor, origin.conversation.id, interaction, %{
               choice_id: "choice-1"
             })

    answers =
      Signals.list_signals!(
        query: [filter: [conversation_id: id, type: "conversation.message.addressed"]]
      )

    assert [answer] = answers
    assert answer.agent_uid == ctx.colleague.uid
    assert answer.human_uid == ctx.human.uid
    assert answer.data["peer_hop_count"] == 0

    refute Enum.any?(
             Signals.list_signals!(query: [filter: [conversation_id: origin.conversation.id]]),
             &(&1.type == "agent.peer_message")
           )
  end

  test "priority and stop supersede only this exchange's pending question", ctx do
    origin = room(ctx.actor, ctx.assistant.uid)
    [event] = Signals.list_signals!(query: [filter: [conversation_id: origin.conversation.id]])
    id = send_peer(ctx, event)
    [peer_event] = Signals.list_signals!(query: [filter: [conversation_id: id]])
    clarify(peer_event)
    send_peer(ctx, event)

    assert PreviewStates.get(peer_event).checkpoint["interactions"]["clarify:choose-report"][
             "state"
           ] == "pending"

    assert {:ok, {result, _}} =
             Repo.transact_top_level(fn ->
               with {:ok, keys, commit} <-
                      Peers.prepare_send(run(ctx, event), %{
                        "target_agent_uid" => ctx.colleague.uid,
                        "message" => "Change the review scope",
                        "priority" => true
                      }),
                    :ok <- Queue.lock_sessions_in_tx(keys),
                    {:ok, result, publications} <- commit.(),
                    do: {:ok, {result, publications}}
             end)

    assert result.details.exchange_id == id

    assert PreviewStates.get(peer_event).checkpoint["interactions"]["clarify:choose-report"][
             "state"
           ] == "superseded"

    next =
      Signals.list_signals!(
        query: [filter: [conversation_id: id, status: :queued], sort: [queue_sequence: :desc]]
      )
      |> hd()

    clarify(next)
    assert {:ok, _} = Peers.stop(ctx.actor, origin.conversation.id, id)

    assert PreviewStates.get(next).checkpoint["interactions"]["clarify:choose-report"]["state"] ==
             "superseded"
  end

  test "attention includes downstream work and deletion stops it while retaining the exchange",
       ctx do
    origin = room(ctx.actor, ctx.assistant.uid)
    [event] = Signals.list_signals!(query: [filter: [conversation_id: origin.conversation.id]])
    id = send_peer(ctx, event)

    assert Enum.any?(
             Conversations.list_rooms(ctx.actor, attention: true),
             &(&1.conversation.id == origin.conversation.id)
           )

    assert {:ok, _} = Conversations.delete(ctx.actor, origin.conversation.id, force_stop: true)
    assert %{origin_conversation_id: nil} = Peers.exchange(id)

    assert [_] =
             Signals.list_signals!(query: [filter: [conversation_id: id, type: "command.stop"]])
  end

  test "creating a group from a private assistant can start with humans only", ctx do
    other = human_fixture().principal

    group =
      room(ctx.actor, nil, %{agent_uids: [], participant_uids: [other.uid], room_mode: :group})

    assert group.conversation.room_mode == :group
    assert group.agents == []
    assert group.pending_inputs == []
  end

  test "renaming the human, assistant and colleague preserves structured DM and peer identities",
       ctx do
    dm = room(ctx.actor, ctx.colleague.uid)
    origin = room(ctx.actor, ctx.assistant.uid)
    [event] = Signals.list_signals!(query: [filter: [conversation_id: origin.conversation.id]])
    id = send_peer(ctx, event)

    assert {:ok, %{principal: human}} =
             Ankole.Principals.rename(ctx.human.uid, "renamed-human@example.com")

    assert {:ok, _} = Ankole.Principals.disable_agent(ctx.colleague.uid)

    assert {:ok, %{principal: colleague}} =
             Ankole.Principals.rename(ctx.colleague.uid, "renamed-legal")

    assert {:ok, _} = Ankole.Principals.disable_agent(ctx.assistant.uid)

    assert {:ok, %{principal: assistant}} =
             Ankole.Principals.rename(ctx.assistant.uid, "renamed-assistant")

    assert %{dm_human_uid: human_uid, dm_colleague_uid: colleague_uid} =
             Conversations.get_conversation!(dm.conversation.id)

    assert {human_uid, colleague_uid} == {human.uid, colleague.uid}
    peer = Peers.exchange(id)
    assert {peer.peer_sender_uid, peer.peer_target_uid} == {assistant.uid, colleague.uid}
    assert Conversations.direct_conversations(human.uid)[colleague.uid] == dm.conversation.id

    Repo.query!(
      "SET CONSTRAINTS conversations_dm_human_fkey, conversations_dm_colleague_fkey, conversations_peer_sender_fkey, conversations_peer_target_fkey IMMEDIATE"
    )
  end

  test "a colleague reads its private archive through the real peer RPC authority while humans stay isolated",
       ctx do
    legal = actor_fixture(ctx.colleague)

    assert {:ok, archive} =
             Ankole.Pod.Pages.create(legal, %{
               title: "Legal archive",
               private_owner_uid: ctx.colleague.uid
             })

    assert {:error, _} = Ankole.Pod.Pages.get(ctx.actor, archive.id)
    origin = room(ctx.actor, ctx.assistant.uid)
    [event] = Signals.list_signals!(query: [filter: [conversation_id: origin.conversation.id]])
    id = send_peer(ctx, event)
    [peer_event] = Signals.list_signals!(query: [filter: [conversation_id: id]])
    assert {:ok, _} = Admission.admit(peer_event, peer_event)

    ref = %Ankole.Sessions.RunRef{
      agent_uid: peer_event.agent_uid,
      session_id: peer_event.session_id,
      signal_id: peer_event.id
    }

    assert {:ok, peer_actor} =
             Ankole.Pod.RPCBroker.actor_for_request(ref, %{worker_id: ctx.colleague.uid})

    assert {:ok, %{page: actual}} = Ankole.Pod.Pages.get(peer_actor, archive.id)
    assert actual.id == archive.id
    other = human_fixture().principal

    other_assistant =
      Ankole.SessionsCase.agent_fixture(%{
        type: :personal_assistant,
        owner_principal_uid: other.uid
      }).principal

    Ankole.ConversationsFixtures.grant_chat(other.uid, ctx.colleague.uid)
    second = room(actor_fixture(other), other_assistant.uid)

    [other_event] =
      Signals.list_signals!(query: [filter: [conversation_id: second.conversation.id]])

    other_id = send_peer(%{ctx | human: other, assistant: other_assistant}, other_event)
    refute id == other_id

    assert {:error, :conversation_not_found} =
             Peers.visible(actor_fixture(other), origin.conversation.id, id)

    assert {:error, :related_context_unavailable} =
             Conversations.recall_related_context(
               %{
                 agent_uid: ctx.colleague.uid,
                 event: hd(Signals.list_signals!(query: [filter: [conversation_id: other_id]]))
               },
               id,
               nil
             )
  end

  test "a peer Action Card stays on the human's original surface and resumes the colleague",
       ctx do
    assert {:ok, page} = Ankole.Pod.Pages.create(ctx.actor, %{title: "Delete this draft"})

    assert {:ok, _} =
             Ankole.Pod.Pages.update_sharing(ctx.actor, page.id, %{
               upserts: [%{principal_uid: ctx.colleague.uid, role: "view", target_scope: "self"}]
             })

    origin = room(ctx.actor, ctx.assistant.uid)
    [event] = Signals.list_signals!(query: [filter: [conversation_id: origin.conversation.id]])
    id = send_peer(ctx, event, [page.id])
    [peer_event] = Signals.list_signals!(query: [filter: [conversation_id: id]])

    card =
      finish_tool(peer_event, "propose_action_card", "delete-draft", %{
        "action_kind" => "pod.page.delete",
        "node_id" => page.id,
        "summary" => "Delete the draft"
      })

    assert card.conversation_id == origin.conversation.id
    card_id = card.rich_content["action_card"]["card_id"]

    assert {:ok, _} =
             Conversations.ActionCards.resolve_native(
               ctx.actor,
               origin.conversation.id,
               card_id,
               :confirm
             )

    assert [wake] =
             Signals.list_signals!(
               query: [filter: [conversation_id: id, type: "conversation.action_card.executed"]]
             )

    assert wake.agent_uid == ctx.colleague.uid
    assert wake.data["peer_hop_count"] == 0
    assert wake.data["origin_session_id"] == event.session_id
  end

  test "external assistant delegations emit only the native Clarify surface and route its answer directly",
       ctx do
    alias Ankole.Conversations.{Observe, InboundBatches, Delivery}
    alias Ankole.SignalsFixtures

    assert {:ok, binding} =
             SignalsFixtures.raw_binding_fixture(%{
               name: "peer-bot",
               adapter: "lark",
               config_ref: "app-config://peer-bot",
               routing_mode: :sender_personal_assistant,
               agent_uid: nil
             })

    author = SignalsFixtures.provider_author_fixture(ctx.human.uid, "peer-human", %{})

    entry =
      SignalsFixtures.group_entry(%{
        author: author,
        channel: %{kind: :im_dm, reply_mode: :entry},
        explicit: true,
        provider_conversation_id: "lark:chat:peer-dm"
      })

    assert {:ok, %{inbound_batch: batch}} = Observe.emit_entry(binding.id, entry)

    assert {:ok, %{signal: event}} =
             InboundBatches.finalize_inbound_batch_by_id(batch.id, now: batch.available_at)

    id = send_peer(ctx, event)
    assert Repo.aggregate(Delivery.Intent, :count) == 0
    [peer_event] = Signals.list_signals!(query: [filter: [conversation_id: id]])
    clarify(peer_event)
    [intent] = Repo.all(Delivery.Intent)
    assert intent.conversation_id == event.conversation_id
    assert intent.binding_id == binding.id
    assert intent.source_signal_id == peer_event.id
    assert :ok = PreviewStates.record_provider_message(peer_event.id, "peer-question")

    action = %{
      "version" => "ankole.interactive_output.action.v1",
      "answerKind" => "choice",
      "interactionId" => "clarify:choose-report",
      "interactionVersion" => 1,
      "controlId" => "clarify-choice",
      "selectedOptionId" => "choice-1",
      "optionValue" => "First",
      "sourceSignalId" => peer_event.id
    }

    assert {:ok, %{status: :accepted, signal: answer}} =
             Observe.emit_action(binding.id, %{
               source_event_id: "answer-peer",
               action_id: "answer-peer",
               provider_conversation_id: "lark:chat:peer-dm",
               provider_message_id: "peer-question",
               provider_thread_id: "peer-question",
               action: %{
                 "name" => "clarify-choice",
                 "value" => action,
                 "operator_principal_uid" => ctx.human.uid
               }
             })

    assert answer.agent_uid == ctx.colleague.uid
    assert answer.conversation_id == id
    assert answer.data["peer_hop_count"] == 0
  end

  test "a background Job delegates through its real fenced RPC and retries create one exchange input",
       ctx do
    origin = room(ctx.actor, ctx.assistant.uid)
    [event] = Signals.list_signals!(query: [filter: [conversation_id: origin.conversation.id]])
    assert {:ok, parent} = Admission.admit(event, event)
    assert {:ok, {:preparing, _}} = Model.prepare(parent)
    route = "peer-job-#{System.unique_integer([:positive])}"
    assert {:ok, _} = Ankole.SessionsCase.admit_worker(route, %{worker_id: ctx.assistant.uid})

    assert {:ok, %{dispatch_event: dispatch}} =
             Ankole.BackgroundAgentJobs.create_with_dispatch(%{
               "agent_uid" => ctx.assistant.uid,
               "owner_session_id" => event.session_id,
               "source_signal_id" => event.id,
               "source_tool_call_id" => "delegate-job",
               "title" => "Review contract",
               "task" => "Ask the legal colleague to review the contract.",
               "reply_route" => %{"conversation_id" => origin.conversation.id}
             })

    assert {:ok, attempt} = Admission.admit(dispatch, dispatch)

    request = %Ankole.RuntimeFabric.V1.PodRequest{
      operation: "chat.send_to_agent",
      params_json:
        Ankole.JSON.encode!(%{
          "call_id" => "job-peer-send",
          "target_agent_uid" => ctx.colleague.uid,
          "message" => "Review the contract"
        })
    }

    rpc_context = %{route: route, worker_id: ctx.assistant.uid, request_id: "peer-job"}
    assert {:ok, first} = Ankole.Pod.RPCBroker.handle_write(attempt.job_ref, request, rpc_context)

    assert {:ok, ^first} =
             Ankole.Pod.RPCBroker.handle_write(attempt.job_ref, request, rpc_context)

    [peer] = Peers.exchanges([origin.conversation.id])
    assert [input] = Signals.list_signals!(query: [filter: [conversation_id: peer.id]])
    assert input.human_uid == ctx.human.uid
    assert input.data["origin_session_id"] == event.session_id
    assert length(Conversations.list_messages!(query: [filter: [conversation_id: peer.id]])) == 1
    stale = %{attempt.job_ref | attempt: attempt.job_ref.attempt + 1}
    assert {:error, _} = Ankole.Pod.RPCBroker.handle_write(stale, request, rpc_context)
  end

  test "runnable human input precedes peer input and background work without bypassing due times",
       ctx do
    origin = room(ctx.actor, ctx.assistant.uid)
    [human] = Signals.list_signals!(query: [filter: [conversation_id: origin.conversation.id]])
    now = DateTime.utc_now(:microsecond)

    make = fn type, at ->
      assert {:ok, input} =
               Repo.transact_top_level(fn ->
                 Signals.accept_in_tx(%{
                   producer: :kernel,
                   source: "test:peer-priority",
                   id: Ecto.UUID.generate(),
                   type: type,
                   sender: ctx.assistant.uid,
                   available_at: at,
                   target: %{
                     agent_uid: ctx.assistant.uid,
                     conversation_id: origin.conversation.id
                   },
                   data: %{}
                 })
               end)

      input
    end

    background = make.("custom.background", now)
    peer = make.("agent.peer_message", now)
    future = make.("conversation.message.addressed", DateTime.add(now, 60))
    assert Enum.map(Queue.due(human, now), & &1.id) == [human.id, peer.id, background.id]
    refute Enum.any?(Queue.due(human, now), &(&1.id == future.id))
  end

  test "a multi-page delegation keeps its recall reference and earlier entries within the inline budget",
       ctx do
    earlier_origin = room(ctx.actor, ctx.assistant.uid, %{text: "Earlier vendor question"})

    [earlier_event] =
      Signals.list_signals!(query: [filter: [conversation_id: earlier_origin.conversation.id]])

    earlier_peer_id = send_peer(ctx, earlier_event)

    pages =
      for index <- 1..10 do
        assert {:ok, page} = Ankole.Pod.Pages.create(ctx.actor, %{title: "Contract #{index}"})

        assert {:ok, _} =
                 Ankole.Pod.Pages.update_sharing(ctx.actor, page.id, %{
                   upserts: [
                     %{principal_uid: ctx.colleague.uid, role: "view", target_scope: "self"}
                   ]
                 })

        page.id
      end

    origin = room(ctx.actor, ctx.assistant.uid, %{text: "Review all ten supplier contracts"})
    [event] = Signals.list_signals!(query: [filter: [conversation_id: origin.conversation.id]])
    batch_peer_id = send_peer(ctx, event, pages)

    dm = room(ctx.actor, ctx.colleague.uid, %{text: "What did you find in that batch?"})
    [dm_event] = Signals.list_signals!(query: [filter: [conversation_id: dm.conversation.id]])
    dm_run = %{agent_uid: ctx.colleague.uid, event: dm_event}

    inline = Conversations.related_context_index(dm_run)
    assert inline != ""
    assert Ankole.Kernel.estimate_o200k_base_tokens(inline) <= 180
    assert inline =~ batch_peer_id
    assert inline =~ earlier_peer_id
    assert inline =~ ",+"

    assert {:ok, recalled} =
             Tools.RelatedContext.execute(dm_run, %{}, %{"ref_id" => batch_peer_id})

    assert %{"ref_id" => ^batch_peer_id, "messages" => [message]} =
             Ankole.JSON.decode!(recalled.output)

    assert Enum.map(message["links"], & &1["id"]) == pages
  end

  test "peer exchange detail distinguishes queued, running, retrying and stops unstarted work immediately",
       ctx do
    origin = room(ctx.actor, ctx.assistant.uid)
    [event] = Signals.list_signals!(query: [filter: [conversation_id: origin.conversation.id]])
    id = send_peer(ctx, event)

    session_key = %{
      agent_uid: ctx.colleague.uid,
      session_id: Ankole.Sessions.Key.conversation(id)
    }

    assert {:ok, %{status: "queued"}} = Peers.detail(ctx.actor, origin.conversation.id, id, nil)
    assert {:ok, _} = Peers.stop(ctx.actor, origin.conversation.id, id)
    assert {:ok, %{status: "idle"}} = Peers.detail(ctx.actor, origin.conversation.id, id, nil)
    assert Queue.due(session_key) == []

    send_peer(ctx, event)
    [peer_event] = Queue.due(session_key)
    assert {:ok, admitted} = Admission.admit(session_key, peer_event)
    assert {:ok, %{status: "running"}} = Peers.detail(ctx.actor, origin.conversation.id, id, nil)

    assert {:ok, _} =
             Run.defer_retry(admitted, %{"code" => "rate_limit_exceeded", "retryable" => true})

    assert {:ok, %{status: "retrying"}} = Peers.detail(ctx.actor, origin.conversation.id, id, nil)
  end

  defp clarify(event),
    do:
      finish_tool(event, "clarify", "choose-report", %{
        "question" => "Which clause?",
        "choices" => [%{"label" => "First"}, %{"label" => "Third"}]
      })

  defp finish_tool(event, name, call_id, arguments) do
    assert {:ok, run} =
             Admission.admit(%{agent_uid: event.agent_uid, session_id: event.session_id}, event)

    assert {:ok, {:preparing, run}} = Model.prepare(run)

    call = %{
      "type" => "function_call",
      "name" => name,
      "call_id" => call_id,
      "arguments" => Ankole.JSON.encode!(arguments)
    }

    assert {:ok, response} =
             start_response_run(%{
               subject_uid: run.agent_uid,
               conversation_id: run.conversation.id,
               round_state: run,
               metadata: %{"request_metadata" => Run.metadata(run)}
             })

    assert {:ok, response} = ResponseCommit.commit_complete(response, [call])

    run = %{
      run
      | model_response: response,
        calls: [call],
        round_calls: [call],
        anchor: response.id
    }

    assert {:ok, tool, args} = Tools.prepare(run, call)
    result = Tools.execute(run, call, tool, args)
    refute result.is_error
    assert {:ok, _} = Run.record_round(%{run | results: %{call["call_id"] => result}})
    assert {:ok, {_state, run}} = Run.restore(run)
    assert {:ok, finalized} = Run.finalize(run)
    assert finalized.posted.signals == []
    List.last(finalized.posted.messages)
  end

  defp room(actor, agent, extra \\ %{}) do
    assert {:ok, detail} =
             Conversations.create(
               actor,
               Map.merge(
                 %{
                   conversation_id: Ecto.UUID.generate(),
                   message_id: Ecto.UUID.generate(),
                   agent_uid: agent,
                   text: "Review the contract"
                 },
                 extra
               )
             )

    detail
  end

  defp run(ctx, event),
    do: %{
      agent_uid: ctx.assistant.uid,
      session_id: event.session_id,
      event: event,
      signal_id: event.id
    }

  defp send_peer(ctx, event, pages \\ []) do
    assert {:ok, {result, _}} =
             Repo.transact_top_level(fn ->
               with {:ok, keys, commit} <-
                      Peers.prepare_send(run(ctx, event), %{
                        "target_agent_uid" => ctx.colleague.uid,
                        "message" => "Review the contract",
                        "page_ids" => pages
                      }),
                    :ok <- Queue.lock_sessions_in_tx(keys),
                    {:ok, result, notifications} <- commit.(),
                    do: {:ok, {result, notifications}}
             end)

    result.details.exchange_id
  end
end
