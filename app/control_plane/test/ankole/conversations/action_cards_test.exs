defmodule Ankole.Conversations.ActionCardsTest do
  use Ankole.DataCase, async: false
  import Ecto.Query
  import Ankole.AIGatewayCase, only: [start_response_run: 1]
  import Ankole.PrincipalsFixtures
  import Ankole.SignalsFixtures
  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_until: 2]

  alias Ankole.AIGateway.ResponseCommit
  alias Ankole.Conversations
  alias Ankole.Conversations.{ActionCard, ActionCards, NativeRoom, Observe}

  alias Ankole.Conversations.Delivery.{
    ActionCardPrompt,
    Intent,
    Interactions,
    PreviewStates,
    ReplyPresentation
  }

  alias Ankole.Pod.{Bases, BaseTable, Pages}
  alias Ankole.Sessions.{Admission, Model, Run, Tools}
  alias Ankole.Signals.Signal
  alias Ecto.Adapters.SQL.Sandbox

  @limits %{
    "query_rows" => 10_000,
    "record_bytes" => 1_000_000,
    "group_count" => 1000,
    "statement_timeout_ms" => 5000
  }

  setup do
    existing_drivers = Ankole.SessionsCase.driver_pids()
    {:ok, _} = Ankole.AppConfigure.put_tenant_by_key("pod.base.limits", @limits)
    alice = human_fixture(%{display_name: "Alice"}).principal
    bob = human_fixture(%{display_name: "Bob"}).principal
    charlie = human_fixture(%{display_name: "Charlie"}).principal
    agent = Ankole.SessionsCase.agent_fixture(%{owner_principal_uid: alice.uid}).principal

    for human <- [alice, bob, charlie] do
      Ankole.ConversationsFixtures.grant_chat(human.uid, agent.uid)
    end

    room_id = Ecto.UUID.generate()

    assert {:ok, _} =
             Conversations.create(actor_fixture(alice), %{
               conversation_id: room_id,
               agent_uid: agent.uid,
               message_id: Ecto.UUID.generate(),
               text: "Help me manage workspace permissions."
             })

    assert {:ok, _} = NativeRoom.manage(actor_fixture(alice), room_id, %{add_uids: [bob.uid]})
    event = Repo.one!(from(s in Signal, where: s.conversation_id == ^room_id))

    %{
      alice: alice,
      bob: bob,
      charlie: charlie,
      agent: agent,
      room_id: room_id,
      event: event,
      existing_drivers: existing_drivers
    }
  end

  for target <- [:document, :base_table] do
    @tag sandbox: false
    @tag target: target
    test "delete card checks #{target} preconditions after waiting for a concurrent writer",
         ctx do
      on_exit(fn ->
        Repo.with_tenant(ctx.tenant.id, fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Ankole.SessionsCase.stop_new_drivers(ctx.existing_drivers)
            delete_agent_fixture_rows(ctx.agent.uid)
            cleanup_tenant!(ctx.tenant)
          end)
        end)
      end)

      actor = actor_fixture(ctx.alice)
      type = if ctx.target == :document, do: "doc", else: "base"

      {:ok, page} =
        Pages.create(actor, %{type: type, title: "Draft target", private_owner_uid: ctx.alice.uid})

      {:ok, _} =
        Ankole.Pod.PagesFixtures.set_sharing(ctx.alice.uid, page.id, %{
          grants: [%{principal_uid: ctx.agent.uid, role: "view"}]
        })

      {arguments, write} =
        if ctx.target == :document do
          validation = Ankole.Kernel.page_validate("<page><p>New content</p></page>")

          {%{"action_kind" => "pod.page.delete", "node_id" => page.id},
           fn -> Ankole.Pod.Documents.write_in_tx(actor, page.id, page.revision, validation) end}
        else
          {:ok, table} = Bases.create_table(actor, page.id, %{name: "Draft table"})

          {%{
             "action_kind" => "pod.base.delete_table",
             "page_id" => page.id,
             "table_id" => table.id
           },
           fn ->
             Bases.Schema.create_field_in_tx(actor, table.id, %{name: "New field", type: "text"})
           end}
        end

      message =
        propose_native_card(ctx, "delete-race", Map.put(arguments, "summary", "Delete target"))

      card_id = message.rich_content["action_card"]["card_id"]

      writer =
        start_unboxed(fn parent ->
          Repo.transact(fn ->
            assert {:ok, _} = result = write.()
            send(parent, {:write_held, self()})

            receive do
              :commit_write -> result
            after
              10_000 -> raise "test did not release writer"
            end
          end)
        end)

      writer_pid = writer.task.pid
      assert_receive {:write_held, ^writer_pid}, 5_000

      confirmer =
        start_unboxed(fn _ ->
          Conversations.resolve_action_card(actor, ctx.room_id, card_id, :confirm)
        end)

      try do
        assert {:ok, true} =
                 wait_until(deadline(5_000), fn ->
                   %{rows: [[blocked]]} =
                     Repo.query!("SELECT $1 = ANY(pg_blocking_pids($2))", [
                       writer.backend_pid,
                       confirmer.backend_pid
                     ])

                   blocked
                 end)
      after
        send(writer.task.pid, :commit_write)
      end

      assert {:ok, _} = Task.await(writer.task, 10_000)
      assert {:ok, _} = Task.await(confirmer.task, 10_000)
      assert Repo.get_by!(ActionCard, id: card_id).status == :stale
      assert {:ok, %{deleted_at: nil}} = Pages.fetch(page.id)

      if table_id = arguments["table_id"] do
        assert {:ok, %{deleting_at: nil}} = Bases.fetch_table(table_id)
        assert Enum.any?(Bases.fields(table_id), &(&1.name == "New field"))
      else
        assert {:ok, %{revision: revision}} = Pages.fetch(page.id)
        assert revision > page.revision
      end
    end
  end

  test "propose_action_card commits a :prepared card, keeps it open across normal chat messages and 403 clicks, executes under LockOrder, and emits [Action Card Executed]",
       ctx do
    alice_actor = actor_fixture(ctx.alice)
    bob_actor = actor_fixture(ctx.bob)

    {:ok, doc} =
      Pages.create(alice_actor, %{title: "Quarterly Forecast", private_owner_uid: ctx.alice.uid})

    # Grant Agent + Bob only `view` so Agent lacks `node_manage` and Bob lacks `node_manage`
    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.alice.uid, doc.id, %{
        grants: [
          %{principal_uid: ctx.agent.uid, role: "view"},
          %{principal_uid: ctx.bob.uid, role: "view"}
        ]
      })

    card_msg =
      propose_native_card(ctx, "share-card-1", %{
        "action_kind" => "pod.page.set_sharing",
        "node_id" => doc.id,
        "summary" => "Grant Charlie\u202E edit access to Quarterly Forecast",
        "grants" => [
          %{"principal_uid" => ctx.agent.uid, "role" => "view"},
          %{"principal_uid" => ctx.bob.uid, "role" => "view"},
          %{"principal_uid" => ctx.charlie.uid, "role" => "edit"}
        ]
      })

    card_id = card_msg.rich_content["action_card"]["card_id"]
    refute String.contains?(card_msg.rich_content["action_card"]["summary"], "\u202E")

    assert %ActionCard{status: :prepared} = Repo.get_by!(ActionCard, id: card_id)

    # 1. A normal chat message in the room MUST NOT supersede a `:prepared` ActionCard
    assert {:ok, _} =
             Conversations.post(bob_actor, ctx.room_id, %{
               message_id: Ecto.UUID.generate(),
               text: "Looks good, Alice can approve."
             })

    assert %ActionCard{status: :prepared} = Repo.get_by!(ActionCard, id: card_id)

    assert PreviewStates.get(ctx.event).checkpoint["interactions"]["action_card:#{card_id}"][
             "state"
           ] ==
             "pending"

    # 2. Bob lacks `node_manage` -> 403 `:forbidden`, card stays `:prepared`!
    assert {:error, :forbidden} =
             Conversations.resolve_action_card(bob_actor, ctx.room_id, card_id, :confirm)

    assert %ActionCard{status: :prepared} = Repo.get_by!(ActionCard, id: card_id)

    # 3. Alice has `node_manage` -> confirms and executes under LockOrder `2 -> 2.5 -> 3 -> 9 -> 11 -> 12`
    assert {:ok, detail} =
             Conversations.resolve_action_card(alice_actor, ctx.room_id, card_id, :confirm)

    persisted = Repo.get_by!(ActionCard, id: card_id)
    assert persisted.status == :executed
    assert persisted.resolved_by_uid == ctx.alice.uid

    # Charlie now has `node_edit` on `doc`!
    assert {:ok, _} = Pages.authorize(actor_fixture(ctx.charlie), doc.id, "node_edit")

    # Updated browser detail projects `status: "executed"`
    presented = Ankole.Pod.Chat.Presentation.detail(detail)
    projected = Enum.find(presented.messages, &(&1.id == card_msg.id))
    assert projected.richContent["action_card"]["status"] == "executed"

    # Wakeup Signal `[Action Card Executed]` was accepted for the Agent
    assert %Signal{type: "conversation.action_card.executed"} =
             wakeup =
             Repo.one!(
               from(s in Signal,
                 where:
                   s.conversation_id == ^ctx.room_id and
                     s.type == "conversation.action_card.executed"
               )
             )

    assert Ankole.Sessions.Prompt.Input.text(Signal.envelope(wakeup), wakeup.type) =~
             "[Action Card Executed]"
  end

  test "transitions to :stale on sharing_version mismatch and executes two-phase pod.base.delete_table atomically",
       ctx do
    alice_actor = actor_fixture(ctx.alice)

    # Part A: CAS `:stale` on `sharing_version` drift
    {:ok, doc} =
      Pages.create(alice_actor, %{title: "Policy Doc", private_owner_uid: ctx.alice.uid})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.alice.uid, doc.id, %{
        grants: [%{principal_uid: ctx.agent.uid, role: "view"}]
      })

    stale_msg =
      propose_native_card(ctx, "stale-card-1", %{
        "action_kind" => "pod.page.set_sharing",
        "node_id" => doc.id,
        "summary" => "Share Policy Doc with Bob",
        "grants" => [
          %{"principal_uid" => ctx.agent.uid, "role" => "view"},
          %{"principal_uid" => ctx.bob.uid, "role" => "view"}
        ]
      })

    stale_card_id = stale_msg.rich_content["action_card"]["card_id"]

    # Mutate sharing concurrently before Alice clicks Confirm so `sharing_version` advances
    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.alice.uid, doc.id, %{
        grants: [
          %{principal_uid: ctx.agent.uid, role: "view"},
          %{principal_uid: ctx.charlie.uid, role: "view"}
        ]
      })

    assert {:ok, _detail} =
             Conversations.resolve_action_card(alice_actor, ctx.room_id, stale_card_id, :confirm)

    assert %ActionCard{status: :stale} = Repo.get_by!(ActionCard, id: stale_card_id)
    assert {:error, :forbidden} = Pages.authorize(actor_fixture(ctx.bob), doc.id, "node_view")

    # Part B: Two-phase `pod.base.delete_table` (`mark_in_tx` + `after_commit` shard cleanup)
    {:ok, base_page} =
      Pages.create(alice_actor, %{
        type: "base",
        title: "Inventory Base",
        private_owner_uid: ctx.alice.uid
      })

    {:ok, table} = Bases.create_table(alice_actor, base_page.id, %{name: "Legacy SKU"})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.alice.uid, base_page.id, %{
        grants: [%{principal_uid: ctx.agent.uid, role: "view"}]
      })

    # Post a fresh human prompt so we have a fresh unadmitted signal in the room
    assert {:ok, _} =
             Conversations.post(alice_actor, ctx.room_id, %{
               message_id: Ecto.UUID.generate(),
               text: "Draft deleting Legacy SKU."
             })

    next_event =
      Repo.one!(
        from(s in Signal,
          where: s.conversation_id == ^ctx.room_id and is_nil(s.completed_at),
          order_by: [desc: s.inserted_at],
          limit: 1
        )
      )

    del_msg =
      propose_native_card(%{ctx | event: next_event}, "del-table-1", %{
        "action_kind" => "pod.base.delete_table",
        "page_id" => base_page.id,
        "table_id" => table.id,
        "summary" => "Delete obsolete Legacy SKU table"
      })

    del_card_id = del_msg.rich_content["action_card"]["card_id"]

    assert {:ok, _detail} =
             Conversations.resolve_action_card(alice_actor, ctx.room_id, del_card_id, :confirm)

    assert %ActionCard{status: :executed} = Repo.get_by!(ActionCard, id: del_card_id)
    assert Repo.get_by(BaseTable, id: table.id) == nil
  end

  test "handles Tier 1 Feishu in-place refresh and Tier 2 WhatsApp append-only receipt + deduped repeat/unauth notices",
       ctx do
    alice_actor = actor_fixture(ctx.alice)

    {:ok, doc_lark} =
      Pages.create(alice_actor, %{title: "Lark Spec", private_owner_uid: ctx.alice.uid})

    {:ok, doc_wa} =
      Pages.create(alice_actor, %{title: "WhatsApp Spec", private_owner_uid: ctx.alice.uid})

    for doc <- [doc_lark, doc_wa] do
      {:ok, _} =
        Ankole.Pod.PagesFixtures.set_sharing(ctx.alice.uid, doc.id, %{
          grants: [%{principal_uid: ctx.agent.uid, role: "view"}]
        })
    end

    # --- Tier 1: Feishu (`lark` adapter supports `PreviewAdapter.refresh`) ---
    lark_card =
      setup_external_action_card(ctx.agent, "lark-binding", "lark", doc_lark, ctx.charlie.uid)

    # Unlinked / unauthorized click keeps card `:prepared`
    assert {:ok, %{status: :unauthorized_action}} =
             Observe.emit_action(
               Ankole.Signals.get_agent_binding!(ctx.agent.uid, "lark-binding").id,
               external_click(lark_card, ctx.bob.uid, "lark-unauth-1", "confirm"),
               now: DateTime.utc_now(:microsecond)
             )

    assert Repo.get_by!(ActionCard, id: lark_card.card.id).status == :prepared

    # Authorized click executes, refreshes checkpoint (`refresh_pending: true`), and appends 0 text receipts on Tier 1
    assert {:ok, %{status: :accepted_action_card}} =
             Observe.emit_action(
               Ankole.Signals.get_agent_binding!(ctx.agent.uid, "lark-binding").id,
               external_click(lark_card, ctx.alice.uid, "lark-confirm-1", "confirm"),
               now: DateTime.utc_now(:microsecond)
             )

    assert Repo.get_by!(ActionCard, id: lark_card.card.id).status == :executed
    assert PreviewStates.get(lark_card.event).checkpoint["refresh_pending"] == true

    assert Repo.aggregate(
             from(d in Intent, where: d.conversation_id == ^lark_card.event.conversation_id),
             :count
           ) == 0

    # --- Tier 2: WhatsApp (`whatsapp` adapter is append-only; no in-place card edit) ---
    wa_card =
      setup_external_action_card(ctx.agent, "wa-binding", "whatsapp", doc_wa, ctx.charlie.uid)

    initial_wa_intents =
      Repo.aggregate(
        from(d in Intent, where: d.conversation_id == ^wa_card.event.conversation_id),
        :count
      )

    # Unauthorized click by Bob appends 1 notice; second unauthorized click by Bob is deduplicated!
    for event_id <- ["wa-unauth-1", "wa-unauth-2"] do
      assert {:ok, %{status: :unauthorized_action}} =
               Observe.emit_action(
                 Ankole.Signals.get_agent_binding!(ctx.agent.uid, "wa-binding").id,
                 external_click(wa_card, ctx.bob.uid, event_id, "confirm"),
                 now: DateTime.utc_now(:microsecond)
               )
    end

    assert Repo.get_by!(ActionCard, id: wa_card.card.id).status == :prepared

    after_unauth_intents =
      Repo.aggregate(
        from(d in Intent, where: d.conversation_id == ^wa_card.event.conversation_id),
        :count
      )

    assert after_unauth_intents == initial_wa_intents + 1

    # Authorized click by Alice executes and appends 1 settlement receipt
    assert {:ok, %{status: :accepted_action_card}} =
             Observe.emit_action(
               Ankole.Signals.get_agent_binding!(ctx.agent.uid, "wa-binding").id,
               external_click(wa_card, ctx.alice.uid, "wa-confirm-1", "confirm"),
               now: DateTime.utc_now(:microsecond)
             )

    assert Repo.get_by!(ActionCard, id: wa_card.card.id).status == :executed

    after_exec_intents =
      Repo.aggregate(
        from(d in Intent, where: d.conversation_id == ^wa_card.event.conversation_id),
        :count
      )

    assert after_exec_intents == after_unauth_intents + 1

    # Repeat click on already-settled card appends at most 1 notice per `(card_id, sender_key)`
    for event_id <- ["wa-repeat-1", "wa-repeat-2"] do
      assert {:ok, %{status: :duplicate_action}} =
               Observe.emit_action(
                 Ankole.Signals.get_agent_binding!(ctx.agent.uid, "wa-binding").id,
                 external_click(wa_card, ctx.alice.uid, event_id, "confirm"),
                 now: DateTime.utc_now(:microsecond)
               )
    end

    final_wa_intents =
      Repo.aggregate(
        from(d in Intent, where: d.conversation_id == ^wa_card.event.conversation_id),
        :count
      )

    assert final_wa_intents == after_exec_intents + 1

    # Unlinked external click (`operator_principal_uid: nil`) rejects without creating any Principal
    unlinked_wa =
      setup_external_action_card(ctx.agent, "wa-unlinked", "whatsapp", doc_wa, ctx.charlie.uid)

    principal_count_before = Repo.aggregate(Ankole.Principals.Principal, :count)

    assert {:ok, %{status: :unauthorized_action}} =
             Observe.emit_action(
               Ankole.Signals.get_agent_binding!(ctx.agent.uid, "wa-unlinked").id,
               external_click(unlinked_wa, nil, "wa-anon-1", "confirm"),
               now: DateTime.utc_now(:microsecond)
             )

    assert Repo.aggregate(Ankole.Principals.Principal, :count) == principal_count_before
    assert Repo.get_by!(ActionCard, id: unlinked_wa.card.id).status == :prepared
  end

  test "supports standalone browser get/resolve for Tier 3 external cards, waiting_choice sidebar status, and source removal cancellation",
       ctx do
    alice_actor = actor_fixture(ctx.alice)
    bob_actor = actor_fixture(ctx.bob)
    charlie_actor = actor_fixture(ctx.charlie)

    {:ok, doc_native} =
      Pages.create(alice_actor, %{title: "Native Card Doc", private_owner_uid: ctx.alice.uid})

    {:ok, doc_email} =
      Pages.create(alice_actor, %{title: "Email Card Doc", private_owner_uid: ctx.alice.uid})

    for doc <- [doc_native, doc_email] do
      {:ok, _} =
        Ankole.Pod.PagesFixtures.set_sharing(ctx.alice.uid, doc.id, %{
          grants: [%{principal_uid: ctx.agent.uid, role: "view"}]
        })
    end

    # 1. Native prepared card surfaces `waiting_choice` in conversation list and cancels cleanly on source removal
    native_msg =
      propose_native_card(ctx, "native-sidebar-1", %{
        "action_kind" => "pod.page.set_sharing",
        "node_id" => doc_native.id,
        "summary" => "Share Native Card Doc",
        "grants" => [
          %{"principal_uid" => ctx.agent.uid, "role" => "view"},
          %{"principal_uid" => ctx.charlie.uid, "role" => "view"}
        ]
      })

    native_card_id = native_msg.rich_content["action_card"]["card_id"]

    rows = Conversations.list_rooms(alice_actor)
    presented_list = Ankole.Pod.Chat.Presentation.conversations(rows)
    room_row = Enum.find(presented_list, &(&1.id == ctx.room_id))
    assert room_row.rowStatus == "waiting_choice"

    assert {:ok, native_standalone} =
             Conversations.get_browser_action_card(alice_actor, native_card_id)

    assert native_standalone["conversation_kind"] == "native"
    assert native_standalone["status"] == "prepared"

    # Removing an external provider source entry cancels its prepared ActionCard under valid LockOrder
    lark_removal =
      setup_external_action_card(ctx.agent, "lark-remove", "lark", doc_native, ctx.charlie.uid)

    {:ok, _} =
      Repo.transact_top_level(fn ->
        locked = Ankole.Signals.lock_signal_in_tx(lark_removal.event.id)

        Ankole.Signals.transition_in_tx(locked, :admit, %{
          last_attempt_at: DateTime.utc_now(:microsecond)
        })
      end)

    {:ok, _} =
      Repo.transact_top_level(fn ->
        locked = Ankole.Signals.lock_signal_in_tx(lark_removal.event.id)

        Ankole.Signals.transition_in_tx(locked, :complete, %{
          completed_at: DateTime.utc_now(:microsecond),
          final_response_id: "resp-lark-remove",
          turn_outcome: "loop_finished"
        })
      end)

    removed_signal = %Ankole.Signals.Signal{
      id: Ecto.UUID.generate(),
      type: "conversation.message.removed",
      agent_uid: lark_removal.event.agent_uid,
      session_id: lark_removal.event.session_id,
      reply_binding_name: lark_removal.event.reply_binding_name,
      reply_binding_id: lark_removal.event.reply_binding_id,
      conversation_id: lark_removal.event.conversation_id,
      provider_message_id: lark_removal.event.provider_message_id
    }

    assert {:ok, [_superseded]} =
             Repo.transact_top_level(fn ->
               :ok =
                 Ankole.Sessions.Queue.lock_session_in_tx(
                   removed_signal.agent_uid,
                   removed_signal.session_id
                 )

               Interactions.supersede_removed_source_in_tx(
                 removed_signal,
                 DateTime.utc_now(:microsecond)
               )
             end)

    assert Repo.get_by!(ActionCard, id: lark_removal.card.id).status == :cancelled

    # 2. Tier 3 (`email`) emits canonical `/?actionCard=<uuid>` link and resolves via standalone browser API
    email_setup =
      setup_external_action_card(ctx.agent, "email-binding", "email", doc_email, ctx.charlie.uid)

    tier3_text =
      ActionCardPrompt.tier3_non_interactive_text(
        %{
          "card_id" => email_setup.card.id,
          "summary" => email_setup.card.summary
        },
        "Please approve sharing."
      )

    assert tier3_text =~ "/?actionCard=#{email_setup.card.id}"

    # Charlie lacks `node_manage` on `doc_email` -> standalone read returns `:not_found`, Bob also `:not_found`
    assert {:error, :not_found} =
             Conversations.get_browser_action_card(charlie_actor, email_setup.card.id)

    assert {:error, :not_found} =
             Conversations.get_browser_action_card(bob_actor, email_setup.card.id)

    # Alice has `node_manage` -> reads and confirms via `resolve_browser_action_card/3`
    assert {:ok, email_standalone} =
             Conversations.get_browser_action_card(alice_actor, email_setup.card.id)

    assert email_standalone["conversation_kind"] == "external"
    assert email_standalone["status"] == "prepared"

    assert {:ok, resolved_standalone} =
             Conversations.resolve_browser_action_card(alice_actor, email_setup.card.id, :confirm)

    assert resolved_standalone["status"] == "executed"
    assert resolved_standalone["resolved_by_uid"] == ctx.alice.uid
    assert {:ok, _} = Pages.authorize(charlie_actor, doc_email.id, "node_view")
  end

  defp start_unboxed(fun) do
    parent = self()
    tenant_id = Repo.tenant_id!()

    task =
      Task.async(fn ->
        Repo.put_tenant_id(tenant_id)

        Sandbox.unboxed_run(Repo, fn ->
          %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:database_task, self(), backend_pid})
          fun.(parent)
        end)
      end)

    task_pid = task.pid
    assert_receive {:database_task, ^task_pid, backend_pid}, 5_000
    %{task: task, backend_pid: backend_pid}
  end

  defp propose_native_card(ctx, call_id, arguments_map) do
    assert {:ok, run} =
             Admission.admit(
               %{agent_uid: ctx.agent.uid, session_id: ctx.event.session_id},
               ctx.event
             )

    assert {:ok, {:preparing, run}} = Model.prepare(run)

    call = %{
      "type" => "function_call",
      "name" => "propose_action_card",
      "call_id" => call_id,
      "arguments" => Ankole.JSON.encode!(arguments_map)
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
    assert {:ok, _journal} = Run.record_round(%{run | results: %{call["call_id"] => result}})
    assert {:ok, {_state, run}} = Run.restore(run)
    assert {:ok, finalized} = Run.finalize(run)
    List.last(finalized.posted.messages)
  end

  defp setup_external_action_card(agent, binding_name, adapter, doc, grant_target_uid) do
    now = DateTime.utc_now(:microsecond)
    binding_fixture(agent.uid, binding_name, :ignore, adapter: adapter)

    %{signal: event} =
      emit_addressed_signal(
        agent.uid,
        binding_name,
        group_entry(%{
          source_event_id: unique_uid("ac-src"),
          provider_message_id: unique_uid("ac-msg"),
          explicit: true
        }),
        now
      )

    {:ok, sharing} = Pages.sharing(Ankole.AuthZ.Actor.new(agent), doc.id)

    {:ok, prepared} =
      ActionCards.prepare_draft(
        %{agent_uid: agent.uid, event: event},
        "ext-call",
        %{
          "action_kind" => "pod.page.set_sharing",
          "node_id" => doc.id,
          "summary" => "Share #{doc.title}",
          "grants" => [
            %{"principal_uid" => agent.uid, "role" => "view"},
            %{"principal_uid" => grant_target_uid, "role" => "view"}
          ]
        }
      )

    assert prepared["preconditions"]["expected_sharing_version"] == sharing.sharing_version
    interaction_id = "action_card:#{prepared["card_id"]}"
    provider_msg_id = unique_uid("provider-card")

    prompt = %{
      "card_id" => prepared["card_id"],
      "interaction_id" => interaction_id,
      "action_kind" => prepared["action_kind"],
      "summary" => prepared["summary"],
      "target_node_id" => prepared["target_node_id"],
      "payload" => prepared["payload"],
      "preconditions" => prepared["preconditions"]
    }

    presentation =
      ReplyPresentation.new()
      |> ReplyPresentation.apply_event("interaction.request", %{
        "revision" => 1,
        "prompt" => prepared["summary"],
        "controls" => [
          %{
            "id" => "confirm",
            "type" => "button",
            "label" => "Confirm & Execute",
            "interaction_id" => interaction_id,
            "source_signal_id" => event.id,
            "control_id" => "action-card-decision",
            "selected_option_id" => "confirm",
            "option_value" => "confirm",
            "revision" => 1
          },
          %{
            "id" => "cancel",
            "type" => "button",
            "label" => "Cancel",
            "interaction_id" => interaction_id,
            "source_signal_id" => event.id,
            "control_id" => "action-card-decision",
            "selected_option_id" => "cancel",
            "option_value" => "cancel",
            "revision" => 1
          }
        ]
      })

    checkpoint =
      %{
        "schema_version" => 1,
        "adapter" => adapter,
        "message_id" => provider_msg_id,
        "streaming_state" => "closed",
        "presentation" => ReplyPresentation.checkpoint(presentation)
      }
      |> then(fn cp ->
        if adapter == "lark" do
          Map.merge(cp, %{
            "card_id" => "lark-card-#{prepared["card_id"]}",
            "element_ids" => ["state", "answer", "actions"]
          })
        else
          cp
        end
      end)

    {:ok, _} = PreviewStates.put_checkpoint(event.id, checkpoint)

    {:ok, card} =
      Repo.transact_top_level(fn ->
        :ok = Ankole.Sessions.Queue.lock_session_in_tx(event.agent_uid, event.session_id)
        {:ok, _} = Interactions.open_in_tx(event, presentation, now)
        ActionCards.commit_prepared_in_tx(event, event.conversation_id, prompt)
      end)

    :ok = PreviewStates.record_provider_message(event.id, provider_msg_id)

    %{
      event: event,
      card: card,
      interaction_id: interaction_id,
      provider_message_id: provider_msg_id
    }
  end

  defp external_click(setup, operator_uid, event_id, decision) do
    %{
      source_event_id: event_id,
      action_id: event_id,
      provider_conversation_id: "lark:chat:group-a",
      provider_message_id: setup.provider_message_id,
      provider_thread_id: setup.provider_message_id,
      action: %{
        "name" => "action-card-decision",
        "value" => %{
          "version" => "ankole.interactive_output.action.v1",
          "answerKind" => "choice",
          "interactionId" => setup.interaction_id,
          "interactionVersion" => 1,
          "controlId" => "action-card-decision",
          "selectedOptionId" => decision,
          "optionValue" => decision,
          "sourceSignalId" => setup.event.id
        },
        "operator_principal_uid" => operator_uid
      }
    }
  end
end
