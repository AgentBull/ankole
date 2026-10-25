defmodule Ankole.Pod.Chat.MultiplayerTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.{Conversations, Repo}
  alias Ankole.Conversations.{Conversation, Message, Native, NativeRoom}

  setup do
    alice = human_fixture(%{display_name: "Alice"}).principal
    bob = human_fixture(%{display_name: "Bob"}).principal
    a = agent_fixture(%{owner_principal_uid: alice.uid, display_name: "Researcher"}).principal
    b = agent_fixture(%{owner_principal_uid: alice.uid, display_name: "Writer"}).principal

    for human <- [alice, bob],
        agent <- [a, b],
        do: Ankole.ConversationsFixtures.grant_chat(human.uid, agent.uid)

    %{alice: alice, bob: bob, a: a, b: b, actor: actor_fixture(alice.uid)}
  end

  test "room membership is private and group mode is monotonic", %{
    alice: alice,
    bob: bob,
    a: a,
    actor: actor
  } do
    detail = create!(alice, a)
    assert detail.conversation.room_mode == :dm
    refute Native.visible_conversation?(actor_fixture(bob.uid), detail.conversation.id)

    assert {:ok, group} =
             Conversations.manage_participants(actor, detail.conversation.id, %{
               add_uids: [bob.uid]
             })

    assert group.conversation.room_mode == :group
    assert Native.visible_conversation?(actor_fixture(bob.uid), detail.conversation.id)

    assert {:ok, removed} =
             Conversations.manage_participants(actor, detail.conversation.id, %{
               remove_uids: [bob.uid]
             })

    assert removed.conversation.room_mode == :group
    refute Native.visible_conversation?(actor_fixture(bob.uid), detail.conversation.id)
  end

  test "mentions invite and wake the named Agent and preserve the human authorization", %{
    alice: alice,
    a: a,
    b: b,
    actor: actor
  } do
    detail = create!(alice, a)
    message_id = Ash.UUIDv7.generate()

    assert {:ok, result} =
             Repo.transact(fn ->
               Conversations.post_in_tx(actor, detail.conversation.id, %{
                 message_id: message_id,
                 text: "Review this",
                 mentions: [%{"type" => "agent", "uid" => b.uid}]
               })
             end)

    assert [signal] = result.events
    assert signal.agent_uid == b.uid
    assert signal.human_uid == alice.uid
    assert signal.message_id == message_id
    assert Conversations.get_conversation!(detail.conversation.id).room_mode == :group

    assert Enum.find(
             NativeRoom.participants(detail.conversation.id),
             &(&1.principal_uid == b.uid)
           )

    message = Conversations.get_message!(message_id)
    assert message.author_display_name == "Alice"
    assert message.mentions == [%{"type" => "agent", "uid" => b.uid}]
  end

  test "detail uses the current Agent roster for its model, status and per-Agent slots", %{
    alice: alice,
    a: a,
    b: b,
    actor: actor
  } do
    detail = create!(alice, a)
    id = detail.conversation.id
    assert {:ok, group} = Conversations.manage_participants(actor, id, %{add_uids: [b.uid]})
    [first, remaining] = group.agents

    assert {:ok, changed} =
             Conversations.manage_participants(actor, id, %{remove_uids: [first.uid]})

    assert [agent] = changed.agents
    assert agent.uid == remaining.uid
    assert changed.agent.uid == remaining.uid
    assert Map.keys(changed.statuses) == [remaining.uid]
    assert changed.status == changed.statuses[remaining.uid]

    assert {:ok, refreshed} = Conversations.get(actor, id)
    projection = Ankole.Pod.Chat.Presentation.detail(refreshed)
    assert Enum.map(projection.pendingQueues, & &1.agentUID) == [remaining.uid]
    assert Enum.map(projection.conversation.agents, & &1.uid) == [remaining.uid]
  end

  test "only opted in Agents wake without a mention and human discussion uses no Agent", %{
    alice: alice,
    a: a,
    b: b,
    actor: actor
  } do
    detail = create!(alice, a)
    id = detail.conversation.id
    assert {:ok, _} = Conversations.manage_participants(actor, id, %{add_uids: [b.uid]})
    assert {:ok, result} = post(actor, id, "Question")
    assert Enum.map(result.events, & &1.agent_uid) == [a.uid]

    assert {:ok, _} =
             Conversations.manage_participants(actor, id, %{
               agent_uid: a.uid,
               may_intervene: false
             })

    assert {:ok, result} = post(actor, id, "Team note")
    assert result.events == []
    assert {:ok, updated} = Conversations.get(actor, id)
    assert Enum.any?(updated.messages, &(&1.text == "Team note"))
  end

  test "latest input projects real Agent recipients without replies or a loaded message", %{
    alice: alice,
    a: a,
    b: b,
    actor: actor
  } do
    detail = create!(alice, a)
    id = detail.conversation.id
    assert {:ok, _} = Conversations.manage_participants(actor, id, %{add_uids: [b.uid]})
    shared_id = Ash.UUIDv7.generate()

    assert {:ok, %{events: targets}} =
             Repo.transact(fn ->
               Native.post_in_tx(actor, id, %{
                 message_id: shared_id,
                 text: "Researcher and Writer, review this",
                 mentions: [
                   %{"type" => "agent", "uid" => a.uid},
                   %{"type" => "agent", "uid" => b.uid}
                 ]
               })
             end)

    assert length(targets) == 2
    assert {:ok, shared} = Conversations.get(actor, id)
    projection = Ankole.Pod.Chat.Presentation.detail(shared)
    assert projection.latestInput.messageID == shared_id
    assert projection.latestInput.authorUID == alice.uid
    assert projection.latestInput.agentUIDs == Enum.sort([a.uid, b.uid])
    refute Enum.any?(projection.messages, &(&1.authorType == "agent"))

    for agent <- [a, b] do
      assert {:ok, _} =
               Conversations.manage_participants(actor, id, %{
                 agent_uid: agent.uid,
                 may_intervene: false
               })
    end

    assert {:ok, %{events: []}} = post(actor, id, "A note for the people in this room")
    assert {:ok, current} = Conversations.get(actor, id)
    note = List.last(current.messages)
    assert {:ok, older} = Conversations.get(actor, id, before_seq: note.seq)
    projection = Ankole.Pod.Chat.Presentation.detail(older)
    assert projection.latestInput == %{messageID: note.id, authorUID: alice.uid, agentUIDs: []}
    refute Enum.any?(projection.messages, &(&1.id == note.id))
  end

  test "a group's sole active Agent follows its listening switch while explicit messages require replies",
       %{
         alice: alice,
         bob: bob,
         a: a,
         actor: actor
       } do
    detail = create!(alice, a)
    id = detail.conversation.id
    assert {:ok, _} = Conversations.manage_participants(actor, id, %{add_uids: [bob.uid]})

    assert {:ok, _} =
             Conversations.manage_participants(actor, id, %{
               agent_uid: a.uid,
               may_intervene: false
             })

    assert {:ok, %{events: []}} = post(actor, id, "Human discussion")

    assert {:ok, _} =
             Conversations.manage_participants(actor, id, %{agent_uid: a.uid, may_intervene: true})

    assert {:ok, %{events: [listener]}} = post(actor, id, "Listen if useful")
    assert listener.data["optional_reply"] == true

    assert {:ok, _} =
             Conversations.manage_participants(actor, id, %{
               agent_uid: a.uid,
               may_intervene: false
             })

    for target <- [
          %{target_agent_uid: a.uid},
          %{mentions: [%{"type" => "agent", "uid" => a.uid}]}
        ] do
      assert {:ok, %{events: [addressed]}} =
               Repo.transact(fn ->
                 Native.post_in_tx(
                   actor,
                   id,
                   Map.merge(target, %{message_id: Ash.UUIDv7.generate(), text: "Please answer"})
                 )
               end)

      refute Map.has_key?(addressed.data, "optional_reply")
    end
  end

  test "preferences belong to each viewer and the read cursor only advances", %{
    alice: alice,
    bob: bob,
    a: a,
    actor: actor
  } do
    detail = create!(alice, a)
    id = detail.conversation.id
    assert {:ok, group} = Conversations.manage_participants(actor, id, %{add_uids: [bob.uid]})

    assert {:ok, _} =
             Conversations.update_conversation(actor, id, %{
               pinned: true,
               muted: true,
               last_read_seq: group.conversation.sequence_high_water
             })

    assert {:ok, _} = Conversations.update_conversation(actor, id, %{last_read_seq: 0})
    alice_member = NativeRoom.participant(id, alice.uid)
    bob_member = NativeRoom.participant(id, bob.uid)
    assert alice_member.pinned_at
    assert alice_member.muted
    assert alice_member.last_read_seq == group.conversation.sequence_high_water
    refute bob_member.pinned_at
    refute bob_member.muted

    assert {:ok, _} =
             Conversations.update_conversation(actor, id, %{pinned: true, muted: false})

    updated = NativeRoom.participant(id, alice.uid)
    assert updated.pinned_at == alice_member.pinned_at
    refute updated.muted
    assert updated.last_read_seq == alice_member.last_read_seq
  end

  test "clearing a custom title restores the first message heading or attachment name", %{
    alice: alice,
    a: a,
    actor: actor
  } do
    local = Ankole.Files.temp_path()
    File.write!(local, "The report brief.")
    on_exit(fn -> File.rm(local) end)

    assert {:ok, upload} =
             Ankole.Conversations.Attachments.Native.upload(
               actor,
               Ash.UUIDv7.generate(),
               "report-brief.txt",
               {:file, local},
               "text/plain"
             )

    for {text, attachments, title} <- [
          {"\n  First message heading\n    Preserve the full message.\n", [],
           "First message heading"},
          {"", [upload.receipt], "report-brief.txt"}
        ] do
      assert {:ok, detail} =
               Ankole.ConversationsFixtures.create(alice.uid, %{
                 conversation_id: Ash.UUIDv7.generate(),
                 message_id: Ash.UUIDv7.generate(),
                 agent_uid: a.uid,
                 text: text,
                 attachments: attachments
               })

      assert detail.conversation.title == title

      assert {:ok, renamed} =
               Conversations.update_conversation(actor, detail.conversation.id, %{
                 title: "Custom report title"
               })

      assert renamed.conversation.title_customized

      assert {:ok, reset} =
               Conversations.update_conversation(actor, detail.conversation.id, %{title: ""})

      refute reset.conversation.title_customized
      assert reset.conversation.title == title
    end
  end

  test "deleted Agents keep group messages and their names while their DM is removed", %{
    alice: alice,
    bob: bob,
    a: a,
    actor: actor
  } do
    dm = create!(alice, a)
    group = create!(alice, a)
    id = group.conversation.id
    assert {:ok, _} = Conversations.manage_participants(actor, id, %{add_uids: [bob.uid]})
    signal = hd(group.pending_inputs)

    assert {:ok, message} =
             Repo.transact(fn ->
               Native.post_native_in_tx(id, signal, "Research complete", :message, [])
             end)

    assert message.author_display_name == "Researcher"
    assert {:ok, %{status: :disabled}} = Ankole.Principals.delete_agent(a.uid)
    assert {:ok, _} = Ankole.Principals.delete_agent(a.uid)
    assert is_nil(Conversations.get_conversation!(dm.conversation.id))
    assert %Conversation{room_mode: :group} = Conversations.get_conversation!(id)

    assert %Message{
             author_uid: nil,
             signal_id: nil,
             author_display_name: "Researcher",
             text: "Research complete"
           } = Conversations.get_message!(message.id)

    assert {:ok, archived} = Conversations.get(actor, id)
    assert archived.agents == []
  end

  test "the sidebar pages pinned rooms before recent rooms and searches message text", %{
    alice: alice,
    a: a,
    actor: actor
  } do
    older = create!(alice, a)
    newer = create!(alice, a)

    assert {:ok, _} =
             Conversations.update_conversation(actor, older.conversation.id, %{pinned: true})

    assert [first] = Conversations.list_rooms(actor, limit: 1)
    assert first.conversation.id == older.conversation.id
    assert [second] = Conversations.list_rooms(actor, limit: 1, cursor: first.conversation.id)
    assert second.conversation.id == newer.conversation.id
    assert {:ok, _} = post(actor, newer.conversation.id, "Needle in history")
    assert [found] = Conversations.list_rooms(actor, query: "needle")
    assert found.conversation.id == newer.conversation.id
  end

  test "queued input for another Agent stays visible in this Agent's context", %{
    alice: alice,
    a: a,
    b: b,
    actor: actor
  } do
    detail = create!(alice, a)
    id = detail.conversation.id
    assert {:ok, _} = Conversations.manage_participants(actor, id, %{add_uids: [b.uid]})
    message_id = Ash.UUIDv7.generate()

    assert {:ok, _} =
             Repo.transact(fn ->
               Native.post_in_tx(actor, id, %{
                 message_id: message_id,
                 text: "Research request",
                 target_agent_uid: a.uid,
                 delivery_mode: "queue"
               })
             end)

    assert {:ok, snapshot} =
             Conversations.context_snapshot(
               id,
               %{agent_uid: b.uid, session_id: Ankole.Sessions.Key.conversation(id)},
               0,
               []
             )

    assert Enum.any?(snapshot.messages, &(&1.id == message_id))

    assert {:ok, own_snapshot} =
             Conversations.context_snapshot(
               id,
               %{agent_uid: a.uid, session_id: Ankole.Sessions.Key.conversation(id)},
               0,
               []
             )

    refute Enum.any?(own_snapshot.messages, &(&1.id == message_id))
  end

  test "anchor rooms require current page access even for a previous participant", %{
    alice: alice,
    bob: bob,
    a: a,
    actor: actor
  } do
    assert {:ok, page} =
             Ankole.Pod.Pages.create(actor, %{title: "Anchor", private_owner_uid: alice.uid})

    assert {:ok, grant} =
             Ankole.AuthZ.create_permission_grant(%{
               principal_uid: bob.uid,
               resource_pattern: "pod:**:#{page.id}:page",
               action: "page_view"
             })

    assert {:ok, detail} =
             Ankole.ConversationsFixtures.create(alice.uid, %{
               conversation_id: Ash.UUIDv7.generate(),
               message_id: Ash.UUIDv7.generate(),
               agent_uid: a.uid,
               page_id: page.id,
               access_scope: "anchor_page",
               text: "Shared discussion"
             })

    id = detail.conversation.id
    bob_actor = actor_fixture(bob.uid)
    assert Native.visible_conversation?(bob_actor, id)
    refute Enum.any?(Conversations.list_rooms(bob_actor), &(&1.conversation.id == id))

    assert Enum.any?(
             Conversations.list_rooms(bob_actor, page_id: page.id),
             &(&1.conversation.id == id)
           )

    assert {:ok, _} = post(bob_actor, id, "I joined through the page")
    assert NativeRoom.participant(id, bob.uid)
    assert Enum.any?(Conversations.list_rooms(bob_actor), &(&1.conversation.id == id))
    assert {:ok, _} = Ankole.AuthZ.delete_permission_grant(grant.id)
    refute Native.visible_conversation?(bob_actor, id)
    refute Enum.any?(Conversations.list_rooms(bob_actor), &(&1.conversation.id == id))
    assert {:error, :conversation_not_found} = post(bob_actor, id, "Cannot post")
  end

  test "page viewers can join a shared DM without permission to call its Agent", ctx do
    viewer = human_fixture(%{display_name: "Page reader"}).principal
    viewer_actor = actor_fixture(viewer)
    {:ok, page} = Ankole.Pod.Pages.create(ctx.actor, %{private_owner_uid: ctx.alice.uid})

    {:ok, _} =
      Ankole.AuthZ.create_permission_grant(%{
        principal_uid: viewer.uid,
        resource_pattern: "pod:**:#{page.id}:page",
        action: "page_view"
      })

    {:ok, room} =
      Ankole.ConversationsFixtures.create(ctx.alice.uid, %{
        conversation_id: Ash.UUIDv7.generate(),
        message_id: Ash.UUIDv7.generate(),
        agent_uid: ctx.a.uid,
        page_id: page.id,
        access_scope: "anchor_page",
        text: "Page chat"
      })

    id = room.conversation.id
    assert Native.authorize_agent(viewer_actor, ctx.a.uid) != :ok

    assert {:error, :forbidden_room_operation} =
             Conversations.update_conversation(viewer_actor, id, %{title: "Not joined"})

    assert {:error, :forbidden_room_operation} =
             Conversations.manage_participants(viewer_actor, id, %{add_uids: [ctx.bob.uid]})

    [unjoined] = Conversations.list_rooms(viewer_actor, page_id: page.id)
    refute Ankole.Pod.Chat.Presentation.conversation(unjoined).rowStatus == "unread"

    assert {:ok, %{events: []}} = post(viewer_actor, id, "A note for the people")
    assert {:ok, joined} = Conversations.get(viewer_actor, id)
    assert joined.conversation.room_mode == :group
    assert NativeRoom.participant(id, viewer.uid).role == :member
    assert Enum.any?(Conversations.list_rooms(viewer_actor), &(&1.conversation.id == id))

    assert {:error, :forbidden} =
             Repo.transact(fn ->
               Native.post_in_tx(viewer_actor, id, %{
                 message_id: Ash.UUIDv7.generate(),
                 text: "Call Agent",
                 target_agent_uid: ctx.a.uid
               })
             end)

    assert {:error, {:forbidden, "chat"}} =
             Conversations.manage_participants(viewer_actor, id, %{
               agent_uid: ctx.a.uid,
               may_intervene: true
             })
  end

  test "page managers own shared room controls without gaining Agent call permission", ctx do
    manager = human_fixture(%{display_name: "Page manager"}).principal
    actor = actor_fixture(manager)
    {:ok, page} = Ankole.Pod.Pages.create(ctx.actor, %{private_owner_uid: ctx.alice.uid})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.alice.uid, page.id, %{
        grants: [%{principal_uid: manager.uid, role: "manage"}]
      })

    {:ok, room} =
      Ankole.ConversationsFixtures.create(ctx.alice.uid, %{
        conversation_id: Ash.UUIDv7.generate(),
        message_id: Ash.UUIDv7.generate(),
        agent_uid: ctx.a.uid,
        page_id: page.id,
        access_scope: "anchor_page",
        text: "Page chat"
      })

    id = room.conversation.id
    assert NativeRoom.owner?(actor, room.conversation)
    [listed] = Conversations.list_rooms(actor, page_id: page.id)
    projection = Ankole.Pod.Chat.Presentation.conversation(listed)
    assert projection.canManage
    assert projection.canDelete

    assert {:ok, _} =
             Conversations.update_conversation(actor, id, %{title: "Managed page discussion"})

    assert {:error, {:forbidden, "chat"}} =
             Conversations.manage_participants(actor, id, %{
               agent_uid: ctx.a.uid,
               may_intervene: true
             })
  end

  test "message retries keep their links mentions and explicit Agent target", ctx do
    room = create!(ctx.alice, ctx.a)
    {:ok, page} = Ankole.Pod.Pages.create(ctx.actor, %{title: "Evidence"})
    id = Ash.UUIDv7.generate()

    attrs = %{
      message_id: id,
      text: "Check evidence",
      target_agent_uid: ctx.a.uid,
      links: [%{kind: :page, id: page.id}],
      mentions: [%{type: :human, uid: ctx.bob.uid}]
    }

    assert {:ok, _} =
             Repo.transact(fn -> Native.post_in_tx(ctx.actor, room.conversation.id, attrs) end)

    canonical = %{
      attrs
      | links: [%{"kind" => "page", "id" => page.id}],
        mentions: [%{"type" => "human", "uid" => ctx.bob.uid}]
    }

    assert {:ok, %{inserted?: false}} =
             Repo.transact(fn ->
               Native.post_in_tx(ctx.actor, room.conversation.id, canonical)
             end)

    for changed <- [
          %{canonical | links: []},
          %{canonical | mentions: []},
          %{canonical | target_agent_uid: nil}
        ] do
      assert {:error, :conversation_conflict} =
               Repo.transact(fn ->
                 Native.post_in_tx(ctx.actor, room.conversation.id, changed)
               end)
    end
  end

  test "retracting one Agent queue keeps the shared message until every target retracts", %{
    alice: alice,
    a: a,
    b: b,
    actor: actor
  } do
    detail = create!(alice, a)
    id = detail.conversation.id
    assert {:ok, _} = Conversations.manage_participants(actor, id, %{add_uids: [b.uid]})
    message_id = Ash.UUIDv7.generate()

    assert {:ok, _} =
             Repo.transact(fn ->
               Native.post_in_tx(actor, id, %{
                 message_id: message_id,
                 text: "Both Agents",
                 mentions: [
                   %{"type" => "agent", "uid" => a.uid},
                   %{"type" => "agent", "uid" => b.uid}
                 ],
                 delivery_mode: "queue"
               })
             end)

    for {agent, withdrawn?} <- [{a, false}, {b, true}] do
      assert {:ok, current} = Conversations.get(actor, id)
      inputs = Enum.filter(current.pending_inputs, &(&1.agent_uid == agent.uid))

      version =
        Ankole.Conversations.NativeQueue.queue_version(current.conversation, inputs, agent.uid)

      assert {:ok, result} =
               Repo.transact(fn ->
                 Conversations.update_queue_in_tx(actor, id, %{
                   agent_uid: agent.uid,
                   action: "retract",
                   message_id: message_id,
                   expected_version: version
                 })
               end)

      assert message_id in result.removed_message_ids == withdrawn?
      assert {:ok, current} = Conversations.get(actor, id)
      assert Enum.any?(current.messages, &(&1.id == message_id)) != withdrawn?
    end
  end

  test "read receipts and personal preferences keep a page viewer outside private membership", %{
    alice: alice,
    bob: bob,
    a: a,
    actor: actor
  } do
    assert {:ok, page} =
             Ankole.Pod.Pages.create(actor, %{title: "Anchor", private_owner_uid: alice.uid})

    assert {:ok, _} =
             Ankole.AuthZ.create_permission_grant(%{
               principal_uid: bob.uid,
               resource_pattern: "pod:**:#{page.id}:page",
               action: "page_view"
             })

    assert {:ok, detail} =
             Ankole.ConversationsFixtures.create(alice.uid, %{
               conversation_id: Ash.UUIDv7.generate(),
               message_id: Ash.UUIDv7.generate(),
               agent_uid: a.uid,
               page_id: page.id,
               access_scope: "anchor_page",
               text: "Page discussion"
             })

    id = detail.conversation.id
    bob_actor = actor_fixture(bob.uid)

    assert {:ok, read} =
             Conversations.update_conversation(bob_actor, id, %{
               last_read_seq: detail.conversation.sequence_high_water,
               pinned: true,
               muted: true
             })

    assert NativeRoom.participant(id, bob.uid).role == :observer
    assert read.conversation.room_mode == :dm
    projection = Ankole.Pod.Chat.Presentation.detail(read)
    refute Enum.any?(projection.conversation.participants, &(&1.uid == bob.uid))
    assert projection.conversation.viewer.pinned
    assert projection.conversation.viewer.muted

    assert {:ok, _} =
             Conversations.update_conversation(actor, id, %{access_scope: "participants"})

    refute Native.visible_conversation?(bob_actor, id)
    assert {:ok, _} = Conversations.manage_participants(actor, id, %{add_uids: [bob.uid]})
    assert NativeRoom.participant(id, bob.uid).role == :member
    assert Native.visible_conversation?(bob_actor, id)
    assert Conversations.get_conversation!(id).room_mode == :group
  end

  test "speaking in a page room promotes a preference-only observer to a member", %{
    alice: alice,
    bob: bob,
    a: a,
    actor: actor
  } do
    assert {:ok, page} =
             Ankole.Pod.Pages.create(actor, %{title: "Anchor", private_owner_uid: alice.uid})

    assert {:ok, _} =
             Ankole.AuthZ.create_permission_grant(%{
               principal_uid: bob.uid,
               resource_pattern: "pod:**:#{page.id}:page",
               action: "page_view"
             })

    assert {:ok, detail} =
             Ankole.ConversationsFixtures.create(alice.uid, %{
               conversation_id: Ash.UUIDv7.generate(),
               message_id: Ash.UUIDv7.generate(),
               agent_uid: a.uid,
               page_id: page.id,
               access_scope: "anchor_page",
               text: "Page discussion"
             })

    bob_actor = actor_fixture(bob.uid)

    assert {:ok, _} =
             Conversations.update_conversation(bob_actor, detail.conversation.id, %{pinned: true})

    assert NativeRoom.participant(detail.conversation.id, bob.uid).role == :observer
    assert {:ok, _} = post(bob_actor, detail.conversation.id, "Join by speaking")
    assert NativeRoom.participant(detail.conversation.id, bob.uid).role == :member
    assert Conversations.get_conversation!(detail.conversation.id).room_mode == :group
  end

  test "a queued shared edit changes every target and rejects the edit when any target starts", %{
    alice: alice,
    a: a,
    b: b,
    actor: actor
  } do
    detail = create!(alice, a)
    id = detail.conversation.id
    assert {:ok, _} = Conversations.manage_participants(actor, id, %{add_uids: [b.uid]})
    message_id = Ash.UUIDv7.generate()

    assert {:ok, _} =
             Repo.transact(fn ->
               Native.post_in_tx(actor, id, %{
                 message_id: message_id,
                 text: "Original shared input",
                 mentions: [
                   %{"type" => "agent", "uid" => a.uid},
                   %{"type" => "agent", "uid" => b.uid}
                 ],
                 delivery_mode: "queue"
               })
             end)

    assert {:ok, current} = Conversations.get(actor, id)
    inputs = Enum.filter(current.pending_inputs, &(&1.agent_uid == a.uid))
    version = Ankole.Conversations.NativeQueue.queue_version(current.conversation, inputs, a.uid)

    assert {:ok, _} =
             Repo.transact(fn ->
               Conversations.update_queue_in_tx(actor, id, %{
                 agent_uid: a.uid,
                 action: "edit",
                 message_id: message_id,
                 text: "Updated shared input",
                 expected_version: version
               })
             end)

    targets = Ankole.Signals.list_signals!(query: [filter: [message_id: message_id]])
    assert length(targets) == 2
    assert Enum.all?(targets, &(&1.data["text"] == "Updated shared input"))
    assert Conversations.get_message!(message_id).text == "Updated shared input"
    target_b = Enum.find(targets, &(&1.agent_uid == b.uid))

    assert {:ok, _} =
             Repo.transact(fn ->
               Ankole.Signals.transition_in_tx(target_b, :start_attempt, %{
                 last_attempt_at: DateTime.utc_now(:microsecond)
               })
             end)

    assert {:ok, current} = Conversations.get(actor, id)
    inputs = Enum.filter(current.pending_inputs, &(&1.agent_uid == a.uid))
    version = Ankole.Conversations.NativeQueue.queue_version(current.conversation, inputs, a.uid)

    assert {:error, :input_already_started} =
             Repo.transact(fn ->
               Conversations.update_queue_in_tx(actor, id, %{
                 agent_uid: a.uid,
                 action: "edit",
                 message_id: message_id,
                 text: "Cannot change running input",
                 expected_version: version
               })
             end)

    assert {:error, :input_already_started} =
             Repo.transact(fn ->
               Conversations.update_queue_in_tx(actor, id, %{
                 agent_uid: a.uid,
                 action: "edit_last",
                 message_id: message_id,
                 text: "Cannot rewrite shared history",
                 expected_text: "Updated shared input",
                 command_id: Ash.UUIDv7.generate(),
                 expected_version: version
               })
             end)

    assert Conversations.get_message!(message_id).text == "Updated shared input"

    assert Enum.all?(
             Ankole.Signals.list_signals!(query: [filter: [message_id: message_id]]),
             &(&1.data["text"] == "Updated shared input")
           )
  end

  test "a shared edit prunes Human mentions while preserving fixed Agent targets", %{
    alice: alice,
    bob: bob,
    a: a,
    b: b,
    actor: actor
  } do
    detail = create!(alice, a)
    id = detail.conversation.id
    assert {:ok, _} = Conversations.manage_participants(actor, id, %{add_uids: [b.uid]})
    message_id = Ash.UUIDv7.generate()
    agents = [%{"type" => "agent", "uid" => a.uid}, %{"type" => "agent", "uid" => b.uid}]
    mentions = agents ++ [%{"type" => "human", "uid" => bob.uid, "displayName" => "Bob"}]

    assert {:ok, _} =
             Repo.transact(fn ->
               Native.post_in_tx(actor, id, %{
                 message_id: message_id,
                 text: "Ask @Bob to review",
                 mentions: mentions,
                 delivery_mode: "queue"
               })
             end)

    assert {:ok, current} = Conversations.get(actor, id)
    inputs = Enum.filter(current.pending_inputs, &(&1.agent_uid == a.uid))
    version = Ankole.Conversations.NativeQueue.queue_version(current.conversation, inputs, a.uid)

    base = %{
      agent_uid: a.uid,
      action: "edit",
      message_id: message_id,
      text: "Review this",
      expected_version: version
    }

    assert {:ok, _} = Repo.transact(fn -> Conversations.update_queue_in_tx(actor, id, base) end)
    assert Conversations.get_message!(message_id).mentions == mentions
    assert {:ok, current} = Conversations.get(actor, id)
    inputs = Enum.filter(current.pending_inputs, &(&1.agent_uid == a.uid))

    before_prune =
      Ankole.Conversations.NativeQueue.queue_version(current.conversation, inputs, a.uid)

    assert {:ok, _} =
             Repo.transact(fn ->
               Conversations.update_queue_in_tx(
                 actor,
                 id,
                 Map.merge(base, %{expected_version: before_prune, mentions: []})
               )
             end)

    assert Conversations.get_message!(message_id).mentions == agents
    targets = Ankole.Signals.list_signals!(query: [filter: [message_id: message_id]])
    assert Enum.sort(Enum.map(targets, & &1.agent_uid)) == Enum.sort([a.uid, b.uid])
    assert Enum.all?(targets, &(&1.data["text"] == "Review this"))

    assert {:error, :queue_changed} =
             Repo.transact(fn ->
               Conversations.update_queue_in_tx(actor, id, %{
                 base
                 | expected_version: before_prune
               })
             end)
  end

  test "a cached browser Actor loses room access when the Human is disabled", %{
    alice: alice,
    bob: bob,
    a: a,
    actor: actor
  } do
    detail = create!(alice, a)

    assert {:ok, _} =
             Conversations.manage_participants(actor, detail.conversation.id, %{
               add_uids: [bob.uid]
             })

    cached = actor_fixture(bob.uid)
    assert Native.visible_conversation?(cached, detail.conversation.id)
    assert {:ok, _} = disable_principal_fixture(bob.uid)
    refute Native.visible_conversation?(cached, detail.conversation.id)
  end

  defp create!(human, agent) do
    {:ok, detail} =
      Ankole.ConversationsFixtures.create(human.uid, %{
        conversation_id: Ash.UUIDv7.generate(),
        message_id: Ash.UUIDv7.generate(),
        agent_uid: agent.uid,
        text: "Start"
      })

    detail
  end

  defp post(actor, id, text),
    do:
      Repo.transact(fn ->
        Conversations.post_in_tx(actor, id, %{message_id: Ash.UUIDv7.generate(), text: text})
      end)
end
