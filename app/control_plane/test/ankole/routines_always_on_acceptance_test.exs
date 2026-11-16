defmodule Ankole.RoutinesAlwaysOnAcceptanceTest do
  use Ankole.SessionsCase

  import Ankole.AIGatewayCase, only: [start_response_run: 1]

  alias Ankole.{Pod, Schedule, Signals}
  alias Ankole.AIGateway.Schemas.Conversation, as: ModelConversation
  alias Ankole.Conversations.Delivery.Intent
  alias Ankole.Pod.Pages
  alias Ankole.Schedule.Schemas.{AgentRoutine, CronSchedule, ScheduledEvent}
  alias Ankole.Sessions.{Admission, Model, Presentation, Queue, Run, Tools}
  alias Ankole.Sessions.Jobs.EnsureDriver

  setup context do
    Ankole.SessionsCase.use_mock_signal_provider_plugin(context)
  end

  describe "Scenario 1: end-to-end hybrid routine flow" do
    test "coalesces Connector bursts, runs checkback wakeup, and projects summaries" do
      %{principal: human} = Ankole.PrincipalsFixtures.human_fixture()
      actor = Ankole.PrincipalsFixtures.actor_fixture(human.uid)
      %{principal: agent} = agent_fixture(%{owner_principal_uid: human.uid})
      Ankole.ConversationsFixtures.grant_chat(human.uid, agent.uid)
      binding_fixture(agent.uid, "secondary", :ignore, adapter: "mock-provider")

      native_room_id = Ecto.UUID.generate()

      stub_driver(%{
        agent_uid: agent.uid,
        session_id: Ankole.Sessions.Key.conversation(native_room_id)
      })

      assert {:ok, native} =
               Ankole.ConversationsFixtures.create(human.uid, %{
                 conversation_id: native_room_id,
                 message_id: Ecto.UUID.generate(),
                 agent_uid: agent.uid,
                 text: "Monitor CRM tickets and post daily summary to /jobs."
               })

      assert {:ok, external} =
               Repo.transact(fn ->
                 Ankole.Conversations.External.observe_conversation_in_tx(
                   %{agent_uid: agent.uid},
                   %{
                     provider_conversation_id: "mock:crm-ops-room",
                     title: "CRM Ops Room",
                     external_kind: :im_group,
                     reply_mode: :channel
                   },
                   @base_time
                 )
               end)

      targets = [
        %{"conversation_id" => native.conversation.id},
        %{
          "conversation_id" => external.id,
          "binding_name" => "secondary",
          "provider_thread_id" => "crm-thread"
        }
      ]

      assert {:ok, page} = Pages.create(actor, %{type: "applet"})
      reference = "applet://#{page.id}"

      assert {:ok, %{routine: routine, cron_schedule: cron}} =
               Schedule.create_routine(
                 %{
                   agent_uid: agent.uid,
                   owner_session_id: Ankole.Sessions.Key.conversation(native.conversation.id),
                   name: "crm-always-on-monitor",
                   idempotency_key: Ecto.UUID.generate(),
                   task: "Triage incoming CRM tickets and compile daily wrap-up.",
                   schedule: %{
                     "kind" => "cron",
                     "expression" => "0 18 * * *",
                     "timezone" => "UTC"
                   },
                   delivery: %{"targets" => targets}
                 },
                 now: @base_time,
                 authorization: Ankole.Principals.WorkAccess.from_sender(human.uid)
               )

      # Default quiet_success is aligned to true ("汇报要宁缺毋滥").
      assert routine.delivery["quiet_success"] == true
      assert cron.delivery["quiet_success"] == true

      session_id = Ankole.Sessions.Key.routine(routine.id)
      stub_driver(%{agent_uid: agent.uid, session_id: session_id})

      assert {:ok, event_binding} =
               Signals.put_event_binding(actor, %{
                 config_ref: reference,
                 agent_routine_id: routine.id,
                 coalesce: %{
                   "enabled" => true,
                   "window_ms" => 5_000,
                   "max_batch_size" => 20,
                   "group_by" => "binding"
                 }
               })

      assert event_binding.agent_routine_id == routine.id

      # Emit 25 burst events: first 20 seal Batch 1 immediately; remaining 5 open Batch 2.
      for seq <- 1..25 do
        assert {:ok, %{signals: [_]}} =
                 Signals.emit(reference, %{
                   "id" => "crm-ticket-#{seq}",
                   "type" => "crm.ticket.created",
                   "subject" => "ticket:#{seq}",
                   "data" => %{
                     "seq" => seq,
                     "priority" => if(seq == 12, do: "urgent", else: "normal")
                   }
                 })
      end

      # Replaying event #5 inside the receipt window deduplicates cleanly without inflating Batch 2.
      assert {:ok, %{signals: [deduped]}} =
               Signals.emit(reference, %{
                 "id" => "crm-ticket-5",
                 "type" => "crm.ticket.created",
                 "subject" => "ticket:5",
                 "data" => %{"seq" => 5, "priority" => "normal"}
               })

      queued_batches =
        Repo.all(
          from(s in Signal,
            where: s.agent_uid == ^agent.uid and s.session_id == ^session_id,
            order_by: [asc: s.inserted_at, asc: s.id]
          )
        )

      assert [batch1, batch2] = queued_batches
      assert deduped.id == batch1.id

      batch1_events = get_in(batch1.extensions, ["ankole_coalesce", "events"])
      assert length(batch1_events) == 20
      assert get_in(batch1.extensions, ["ankole_coalesce", "sealed"]) == true
      assert Enum.map(batch1_events, &get_in(&1, ["data", "seq"])) == Enum.to_list(1..20)

      # Sealing on max_batch_size pulls available_at earlier so Batch 1 is immediately ready!
      assert DateTime.compare(batch1.available_at, DateTime.utc_now(:microsecond)) in [:lt, :eq]

      batch2_events = get_in(batch2.extensions, ["ankole_coalesce", "events"])
      assert length(batch2_events) == 5
      assert get_in(batch2.extensions, ["ankole_coalesce", "sealed"]) == false
      assert Enum.map(batch2_events, &get_in(&1, ["data", "seq"])) == Enum.to_list(21..25)
      assert DateTime.after?(batch2.available_at, batch1.available_at)

      native_msg_count_before =
        Repo.aggregate(
          from(m in Ankole.Conversations.Message,
            where: m.conversation_id == ^native.conversation.id
          ),
          :count
        )

      # Execute Batch 1: schedule a 15m check_back_later for ticket #12 and finish with silent_success + summary.
      checkback_call = %{
        "type" => "function_call",
        "name" => "check_back_later",
        "call_id" => "cb_create",
        "arguments" =>
          Ankole.JSON.encode!(%{
            "action" => "create",
            "reason" => "Verify ticket #12 urgent SLA",
            "check" => "Alert both channels if ticket #12 is still unassigned",
            "schedule" => %{"after" => %{"value" => 15, "unit" => "minute"}}
          })
      }

      finish_batch1_call = %{
        "type" => "function_call",
        "name" => "finish_scheduled",
        "call_id" => "finish_b1",
        "arguments" =>
          Ankole.JSON.encode!(%{
            "outcome" => "silent_success",
            "reply" => nil,
            "summary" => "Triaged 20 CRM tickets; scheduled 15m SLA checkback for urgent #12."
          })
      }

      assert {:ok, %{status: :completed}} =
               execute_scheduled_calls(
                 agent.uid,
                 batch1,
                 [checkback_call, finish_batch1_call],
                 :silent
               )

      reloaded_b1 = Repo.reload!(batch1)
      assert reloaded_b1.status == :completed
      assert reloaded_b1.turn_outcome == "silent"

      assert reloaded_b1.turn_summary ==
               "Triaged 20 CRM tickets; scheduled 15m SLA checkback for urgent #12."

      # Silent success produces zero chat room messages and zero outbound intents.
      assert Repo.aggregate(
               from(m in Ankole.Conversations.Message,
                 where: m.conversation_id == ^native.conversation.id
               ),
               :count
             ) == native_msg_count_before

      assert Repo.aggregate(from(i in Intent, where: i.source_signal_id == ^batch1.id), :count) ==
               0

      # Locate the scheduled checkback in routine:<id> and fire it when due.
      checkback =
        Repo.one!(
          from(e in ScheduledEvent,
            where:
              e.agent_uid == ^agent.uid and e.session_id == ^session_id and
                e.kind == "check_back_later" and e.status == :scheduled
          )
        )

      assert checkback.wake_payload["quiet_success"] == true

      assert {:ok, %{signal: wakeup_signal}} =
               Schedule.fire_due_event(checkback.id,
                 now: DateTime.add(checkback.due_at, 1, :second)
               )

      assert wakeup_signal.session_id == session_id
      assert get_in(wakeup_signal.data, ["wake_payload", "delivery", "targets"]) == targets

      # Complete Batch 2 first (FIFO queue order in routine:<id>) with silent_success so wakeup_signal becomes queue head.
      finish_batch2_call = %{
        "type" => "function_call",
        "name" => "finish_scheduled",
        "call_id" => "finish_b2",
        "arguments" =>
          Ankole.JSON.encode!(%{
            "outcome" => "silent_success",
            "reply" => nil,
            "summary" => "Triaged remaining 5 CRM tickets; all normal."
          })
      }

      batch2_due = DateTime.add(batch2.available_at, 1, :second)

      assert {:ok, %{status: :completed}} =
               execute_scheduled_calls(
                 agent.uid,
                 Repo.reload!(batch2),
                 [finish_batch2_call],
                 :silent,
                 now: batch2_due
               )

      # Now execute the checkback wakeup Turn with outcome="reply" -> delivers to BOTH targets!
      finish_wakeup_call = %{
        "type" => "function_call",
        "name" => "finish_scheduled",
        "call_id" => "finish_wakeup",
        "arguments" =>
          Ankole.JSON.encode!(%{
            "outcome" => "reply",
            "reply" => "SLA Alert: Ticket #12 remains unassigned after 15 minutes.",
            "summary" => "Escalated unassigned urgent ticket #12 to native + external rooms."
          })
      }

      assert {:ok,
              %{
                status: :completed,
                posted: %{messages: [wakeup_msg], intents: [wakeup_intent]}
              }} =
               execute_scheduled_calls(
                 agent.uid,
                 Repo.reload!(wakeup_signal),
                 [finish_wakeup_call],
                 :loop_finished,
                 now: DateTime.add(checkback.due_at, 2, :second)
               )

      assert wakeup_msg.conversation_id == native.conversation.id
      assert wakeup_msg.text == "SLA Alert: Ticket #12 remains unassigned after 15 minutes."
      assert wakeup_intent.conversation_id == external.id
      assert wakeup_intent.binding_name == "secondary"

      assert Repo.reload!(wakeup_signal).turn_summary ==
               "Escalated unassigned urgent ticket #12 to native + external rooms."

      # Fire the Hybrid Routine's daily Cron slot in the exact same routine:<id> session/workspace.
      assert {:ok, %{signal: cron_signal}} =
               Schedule.fire_cron(cron.id, now: cron.next_fire_at)

      assert cron_signal.session_id == session_id

      finish_cron_call = %{
        "type" => "function_call",
        "name" => "finish_scheduled",
        "call_id" => "finish_cron",
        "arguments" =>
          Ankole.JSON.encode!(%{
            "outcome" => "silent_success",
            "reply" => nil,
            "summary" => "Daily wrap-up: 25 tickets triaged, 1 urgent SLA escalation delivered."
          })
      }

      assert {:ok, %{status: :completed}} =
               execute_scheduled_calls(
                 agent.uid,
                 cron_signal,
                 [finish_cron_call],
                 :silent,
                 now: DateTime.add(cron.next_fire_at, 5, :second)
               )

      # Verify Pod /jobs outer card summary and Routine Detail run history projections!
      assert {:ok, board} = Pod.JobsBoard.list(actor)
      routine_card = Enum.find(board.items, &(&1.id == "cron:#{routine.id}"))
      assert routine_card != nil

      assert routine_card.summary ==
               "Daily wrap-up: 25 tickets triaged, 1 urgent SLA escalation delivered."

      assert {:ok, detail} = Pod.JobsBoard.routine_detail(actor, "cron", routine.id)
      summaries = Enum.map(detail.runs, & &1.summary)

      assert "Daily wrap-up: 25 tickets triaged, 1 urgent SLA escalation delivered." in summaries
      assert "Escalated unassigned urgent ticket #12 to native + external rooms." in summaries
      assert "Triaged remaining 5 CRM tickets; all normal." in summaries
      assert "Triaged 20 CRM tickets; scheduled 15m SLA checkback for urgent #12." in summaries
    end
  end

  describe "Scenario 2: crash recovery of turn_summary" do
    test "restores turn_summary from RoundState journal after crash" do
      %{principal: human} = Ankole.PrincipalsFixtures.human_fixture()
      %{principal: agent} = agent_fixture(%{owner_principal_uid: human.uid})
      room_id = native_room_fixture(human.uid, agent.uid)

      assert {:ok, %{routine: routine, cron_schedule: cron}} =
               Schedule.create_routine(
                 %{
                   agent_uid: agent.uid,
                   owner_session_id: Ankole.Sessions.Key.conversation(room_id),
                   name: "invoice-audit",
                   idempotency_key: Ecto.UUID.generate(),
                   task: "Verify hourly invoice settlement batch.",
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 3_600_000,
                     "anchor_at" => DateTime.to_iso8601(@base_time),
                     "timezone" => "UTC"
                   },
                   delivery: %{"targets" => [%{"conversation_id" => room_id}]}
                 },
                 now: @base_time,
                 authorization: Ankole.Principals.WorkAccess.from_sender(human.uid)
               )

      session_id = Ankole.Sessions.Key.routine(routine.id)
      stub_driver(%{agent_uid: agent.uid, session_id: session_id})

      assert {:ok, %{signal: event}} = Schedule.fire_cron(cron.id, now: cron.next_fire_at)

      key = %{agent_uid: agent.uid, session_id: session_id}
      assert {:ok, run} = Admission.admit(key, event, now: cron.next_fire_at)
      assert :ok = Presentation.start(run, self())
      assert {:ok, {:preparing, run}} = Model.prepare(run)

      call = %{
        "type" => "function_call",
        "name" => "finish_scheduled",
        "call_id" => "finish_crash",
        "arguments" =>
          Ankole.JSON.encode!(%{
            "outcome" => "silent_success",
            "reply" => nil,
            "summary" => "Crash-recovered summary: 8 invoices verified, 0 discrepancies."
          })
      }

      response = complete_response_items(agent.uid, event, [call])
      run = %{run | model_response: response, calls: [call], round_calls: [call]}
      assert {:ok, tool, args} = Tools.prepare(run, call)
      result = Tools.execute(run, call, tool, args)

      assert result.turn_summary ==
               "Crash-recovered summary: 8 invoices verified, 0 discrepancies."

      # Persist journal to PostgreSQL, then discard the in-memory `results` map to simulate process crash!
      assert {:ok, journal} = Run.record_round(%{run | results: %{call["call_id"] => result}})

      started_signal = Repo.reload!(event)
      assert started_signal.status == :running
      assert is_nil(started_signal.turn_summary)

      assert {:ok, crashed_reclaim_run} =
               Admission.admit(key, started_signal,
                 now: DateTime.add(cron.next_fire_at, 2, :second)
               )

      assert crashed_reclaim_run.results == %{}
      assert {:ok, {_state, restored_run}} = Run.restore(crashed_reclaim_run)

      restored_tool_result = Map.fetch!(restored_run.results, "finish_crash")
      assert restored_tool_result.outcome == :silent

      assert restored_tool_result.turn_summary ==
               "Crash-recovered summary: 8 invoices verified, 0 discrepancies."

      assert {:ok, %{status: :completed}} =
               Run.finalize(
                 %{restored_run | event: Repo.reload!(event), anchor: journal.message.id},
                 :silent
               )

      committed = Repo.reload!(event)
      assert committed.status == :completed
      assert committed.turn_outcome == "silent"

      assert committed.turn_summary ==
               "Crash-recovered summary: 8 invoices verified, 0 discrepancies."
    end
  end

  describe "Scenario 3: admission race & earliest-due wakeup" do
    test "defers unsealed batch admission and wakes at MIN(available_at)" do
      %{principal: human} = Ankole.PrincipalsFixtures.human_fixture()
      actor = Ankole.PrincipalsFixtures.actor_fixture(human.uid)
      %{principal: agent} = agent_fixture(%{owner_principal_uid: human.uid})
      room_id = native_room_fixture(human.uid, agent.uid)

      assert {:ok, page} = Pages.create(actor, %{type: "applet"})
      reference = "applet://#{page.id}"

      assert {:ok, %{routine: routine}} =
               Schedule.create_routine(
                 %{
                   agent_uid: agent.uid,
                   owner_session_id: Ankole.Sessions.Key.conversation(room_id),
                   name: "coalesce-race-routine",
                   idempotency_key: Ecto.UUID.generate(),
                   task: "Batch incoming alerts.",
                   delivery: %{"targets" => [%{"conversation_id" => room_id}]}
                 },
                 now: @base_time,
                 authorization: Ankole.Principals.WorkAccess.from_sender(human.uid)
               )

      session_id = Ankole.Sessions.Key.routine(routine.id)
      key = %{agent_uid: agent.uid, session_id: session_id}
      stub_driver(key)

      assert {:ok, _binding} =
               Signals.put_event_binding(actor, %{
                 config_ref: reference,
                 agent_routine_id: routine.id,
                 coalesce: %{
                   "enabled" => true,
                   "window_ms" => 30_000,
                   "max_batch_size" => 20
                 }
               })

      assert {:ok, %{signals: [batch]}} =
               Signals.emit(reference, %{
                 "id" => "race-evt-1",
                 "type" => "alert.fired",
                 "data" => %{"n" => 1}
               })

      now = DateTime.utc_now(:microsecond)
      assert DateTime.after?(batch.available_at, now)

      # Simulate a stale snapshot that appeared due before locking the Signal row in admit_in_tx.
      stale_snapshot = %{batch | available_at: DateTime.add(now, -1, :second)}

      assert {:ok, %{status: :deferred, signal: deferred}} =
               Admission.admit(key, stale_snapshot, now: now)

      assert deferred.id == batch.id
      assert is_nil(Repo.reload!(batch).last_attempt_at)
      assert Repo.reload!(batch).status == :queued

      # Part B: Two queued signals with S1 (older, +60s) and S2 (newer, +5s) -> EnsureDriver wakes at MIN(available_at) = +5s!
      s1_due = DateTime.add(now, 60, :second)
      s2_due = DateTime.add(now, 5, :second)

      Repo.update!(Ecto.Changeset.change(Repo.reload!(batch), available_at: s1_due))

      {:ok, s2} =
        Repo.transact(fn ->
          Signals.accept_in_tx(%{
            producer: :kernel,
            target: key,
            sender: agent.uid,
            source: "ankole:routine:#{routine.id}",
            id: Ecto.UUID.generate(),
            type: "routine.manual_run",
            data: %{},
            available_at: s2_due
          })
        end)

      assert Queue.oldest_open(agent.uid, session_id).id == batch.id

      assert DateTime.compare(Queue.earliest_open_available_at(agent.uid, session_id), s2_due) ==
               :eq

      assert s2.available_at == s2_due

      # Clear any existing EnsureDriver job for this session so rebuild schedules fresh.
      Repo.delete_all(
        from(j in Oban.Job,
          where:
            j.worker == "Ankole.Sessions.Jobs.EnsureDriver" and
              fragment("?->>'agent_uid' = ?", j.args, ^agent.uid) and
              fragment("?->>'session_id' = ?", j.args, ^session_id)
        )
      )

      assert {:ok, :idle} = Run.rebuild(key, now)

      ensure_job =
        Repo.one!(
          from(j in Oban.Job,
            where:
              j.worker == ^inspect(EnsureDriver) and
                fragment("?->>'agent_uid' = ?", j.args, ^agent.uid) and
                fragment("?->>'session_id' = ?", j.args, ^session_id)
          )
        )

      # Scheduled at +5s (S2), NOT +60s (S1 oldest_open)!
      assert abs(DateTime.diff(ensure_job.scheduled_at, s2_due, :second)) <= 1
    end
  end

  describe "Scenario 4: mid-window edit, pause/resume, finite Cron" do
    test "seals batch on edit, revokes queued work on pause, and keeps active on finite Cron" do
      %{principal: human} = Ankole.PrincipalsFixtures.human_fixture()
      actor = Ankole.PrincipalsFixtures.actor_fixture(human.uid)
      %{principal: agent} = agent_fixture(%{owner_principal_uid: human.uid})
      room_id = native_room_fixture(human.uid, agent.uid)

      assert {:ok, page} = Pages.create(actor, %{type: "applet"})
      reference = "applet://#{page.id}"

      assert {:ok, %{routine: routine, cron_schedule: cron}} =
               Schedule.create_routine(
                 %{
                   agent_uid: agent.uid,
                   owner_session_id: Ankole.Sessions.Key.conversation(room_id),
                   name: "hybrid-lifecycle-routine",
                   idempotency_key: Ecto.UUID.generate(),
                   task: "Initial rubric v1",
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 600_000,
                     "anchor_at" => DateTime.to_iso8601(@base_time),
                     "timezone" => "UTC",
                     "occurrences" => %{"count" => 1}
                   },
                   delivery: %{"targets" => [%{"conversation_id" => room_id}]}
                 },
                 now: @base_time,
                 authorization: Ankole.Principals.WorkAccess.from_sender(human.uid)
               )

      session_id = Ankole.Sessions.Key.routine(routine.id)
      stub_driver(%{agent_uid: agent.uid, session_id: session_id})

      assert {:ok, _binding} =
               Signals.put_event_binding(actor, %{
                 config_ref: reference,
                 agent_routine_id: routine.id,
                 coalesce: %{"enabled" => true, "window_ms" => 60_000, "max_batch_size" => 20}
               })

      # Emit 2 events into open Batch A (definition_version 1).
      assert {:ok, %{signals: [batch_a1]}} =
               Signals.emit(reference, %{
                 "id" => "edit-1",
                 "type" => "item.created",
                 "data" => %{"v" => 1}
               })

      assert {:ok, %{signals: [batch_a2]}} =
               Signals.emit(reference, %{
                 "id" => "edit-2",
                 "type" => "item.created",
                 "data" => %{"v" => 2}
               })

      assert batch_a1.id == batch_a2.id
      assert get_in(batch_a2.extensions, ["ankole_coalesce", "sealed"]) == false
      assert get_in(batch_a2.extensions, ["ankole_routine", "definition_version"]) == 1

      # Seed an active AIGateway :routine conversation to verify rotation on task edit.
      assert {:ok, conv} =
               Ankole.AIGatewayCase.ensure_conversation(
                 agent.uid,
                 session_id,
                 kind: :routine
               )

      assert is_nil(conv.ended_at)

      # Mid-window task edit bumps definition_version, seals Batch A, and closes the active model conversation!
      t_edit = DateTime.add(@base_time, 10, :second)

      assert {:ok, edited_routine} =
               Schedule.update_routine(routine.id, %{task: "Updated rubric v2"}, now: t_edit)

      assert edited_routine.definition_version == 2
      assert get_in(Repo.reload!(batch_a1).extensions, ["ankole_coalesce", "sealed"]) == true
      assert Repo.get!(ModelConversation, conv.id).ended_at != nil

      # Emitting a 3rd event opens a brand-new Batch B carrying definition_version == 2!
      assert {:ok, %{signals: [batch_b]}} =
               Signals.emit(reference, %{
                 "id" => "edit-3",
                 "type" => "item.created",
                 "data" => %{"v" => 3}
               })

      assert batch_b.id != batch_a1.id
      assert get_in(batch_b.extensions, ["ankole_routine", "definition_version"]) == 2
      assert get_in(batch_b.extensions, ["ankole_routine", "task"]) == "Updated rubric v2"

      # Schedule a pending checkback in routine:<id>, then pause the Routine.
      source = Ankole.WorkFixtures.service_source(agent.uid)

      assert {:ok, %{scheduled_event: pending_cb}} =
               Schedule.create_check_back_later(
                 %{
                   source_signal_id: source.id,
                   agent_uid: agent.uid,
                   session_id: session_id,
                   tool_call_id: "cb_pause_test",
                   idempotency_key: Ecto.UUID.generate(),
                   schedule: %{
                     "at" => DateTime.to_iso8601(DateTime.add(@base_time, 1800, :second)),
                     "timezone" => "UTC"
                   },
                   reason: "Follow up",
                   check: "Check status"
                 },
                 now: t_edit
               )

      t_pause = DateTime.add(@base_time, 20, :second)
      assert {:ok, paused_routine} = Schedule.pause_routine(routine.id, now: t_pause)
      assert paused_routine.status == :paused
      assert Repo.get!(CronSchedule, cron.id).status == :paused
      assert Repo.get!(ScheduledEvent, pending_cb.id).status == :cancelled

      for sig_id <- [batch_a1.id, batch_b.id] do
        revoked = Repo.get!(Signal, sig_id)
        assert revoked.status == :dead_letter
        assert revoked.dead_letter_reason["reason"] == "routine_paused"
      end

      # On /jobs, paused Routine with revoked queued signals stays in scheduled/paused (not failed!).
      assert {:ok, board} = Pod.JobsBoard.list(actor)
      paused_card = Enum.find(board.items, &(&1.id == "cron:#{routine.id}"))
      assert paused_card.column == :scheduled
      assert paused_card.status == "paused"
      assert paused_card.attention == false

      # Resume 2 hours later: advances next_fire_at forward from `now` without backfilling missed 10m slots!
      t_resume = DateTime.add(@base_time, 7_200, :second)
      assert {:ok, resumed_routine} = Schedule.resume_routine(routine.id, now: t_resume)
      resumed_cron = Repo.get!(CronSchedule, cron.id)

      assert resumed_routine.status == :active
      assert DateTime.after?(resumed_cron.next_fire_at, t_resume)

      # Fire the 1-occurrence finite Cron: Cron completes, while AgentRoutine remains :active because Connector Binding is still enabled!
      assert {:ok, %{signal: _cron_sig}} =
               Schedule.fire_cron(cron.id, now: resumed_cron.next_fire_at)

      assert Repo.get!(CronSchedule, cron.id).status == :completed
      assert Repo.get!(AgentRoutine, routine.id).status == :active

      assert {:ok, %{signals: [post_cron_sig]}} =
               Signals.emit(reference, %{
                 "id" => "post-cron-exhaustion",
                 "type" => "item.created",
                 "data" => %{"v" => 4}
               })

      assert post_cron_sig.status == :queued
    end
  end

  describe "Scenario 5: pre-Signal failure & delivery warning" do
    test "surfaces unlinked cron_fire failures and stopped Delivery.Intent warnings" do
      %{principal: human} = Ankole.PrincipalsFixtures.human_fixture()
      actor = Ankole.PrincipalsFixtures.actor_fixture(human.uid)
      %{principal: agent} = agent_fixture(%{owner_principal_uid: human.uid})
      Ankole.ConversationsFixtures.grant_chat(human.uid, agent.uid)
      binding_fixture(agent.uid, "secondary", :ignore, adapter: "mock-provider")

      assert {:ok, external} =
               Repo.transact(fn ->
                 Ankole.Conversations.External.observe_conversation_in_tx(
                   %{agent_uid: agent.uid},
                   %{
                     provider_conversation_id: "mock:warning-room",
                     title: "Warning Room",
                     external_kind: :im_group,
                     reply_mode: :channel
                   },
                   @base_time
                 )
               end)

      targets = [
        %{
          "conversation_id" => external.id,
          "binding_name" => "secondary",
          "provider_thread_id" => "warn-thread"
        }
      ]

      assert {:ok, %{routine: routine, cron_schedule: cron}} =
               Schedule.create_routine(
                 %{
                   agent_uid: agent.uid,
                   binding_name: "secondary",
                   owner_session_id: Ankole.Sessions.Key.conversation(external.id),
                   name: "delivery-and-entry-audit",
                   idempotency_key: Ecto.UUID.generate(),
                   task: "Audit SLA and alert external room.",
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 3_600_000,
                     "anchor_at" => DateTime.to_iso8601(@base_time),
                     "timezone" => "UTC"
                   },
                   delivery: %{"targets" => targets}
                 },
                 now: @base_time,
                 authorization: Ankole.Principals.WorkAccess.from_sender(human.uid)
               )

      session_id = Ankole.Sessions.Key.routine(routine.id)
      stub_driver(%{agent_uid: agent.uid, session_id: session_id})

      # 1. Trigger a real pre-Signal Cron fire failure by bumping human access_version past cron.principal_access_version,
      #    then firing at max_attempts so Fire.persist_cron_error records a failed cron_fire ScheduledEvent with signal_id == nil!
      stale_cron = Repo.get!(CronSchedule, cron.id)

      stale_cron
      |> AshPostgres.DataLayer.to_ecto()
      |> Ecto.Changeset.change(%{human_access_version: human.access_version + 99})
      |> Repo.update!()

      assert {:error, _reason} =
               Schedule.fire_cron(cron.id,
                 now: cron.next_fire_at,
                 attempt: 3,
                 max_attempts: 3
               )

      failed_entry =
        Repo.one!(
          from(e in ScheduledEvent,
            where:
              e.cron_schedule_id == ^cron.id and e.kind == "cron_fire" and e.status == :failed
          )
        )

      assert is_nil(failed_entry.signal_id)

      # Restore valid human_access_version so the next Cron slot fires cleanly.
      Repo.get!(CronSchedule, cron.id)
      |> AshPostgres.DataLayer.to_ecto()
      |> Ecto.Changeset.change(%{human_access_version: human.access_version})
      |> Repo.update!()

      next_slot = Repo.get!(CronSchedule, cron.id).next_fire_at
      assert {:ok, %{signal: ok_signal}} = Schedule.fire_cron(cron.id, now: next_slot)

      reply_call = %{
        "type" => "function_call",
        "name" => "finish_scheduled",
        "call_id" => "finish_warn",
        "arguments" =>
          Ankole.JSON.encode!(%{
            "outcome" => "reply",
            "reply" => "Critical alert for external channel",
            "summary" => "Prepared critical external alert."
          })
      }

      assert {:ok, %{status: :completed, posted: %{intents: [intent]}}} =
               execute_scheduled_calls(
                 agent.uid,
                 ok_signal,
                 [reply_call],
                 :loop_finished,
                 now: DateTime.add(next_slot, 2, :second)
               )

      # 2. Dispatch the external Delivery.Intent against a permanently failing adapter so the Intent stops!
      permanent_failure =
        delivery_adapter([:post_entry], fn _ ->
          {:error, {:reply_delivery, :permanent, %{"code" => "channel_archived"}}}
        end)

      assert {:ok, %Intent{status: :failed, next_attempt_at: nil}} =
               Task.async(
                 Repo.bind_tenant(fn ->
                   Ankole.Conversations.Delivery.dispatch(
                     agent.uid,
                     "secondary",
                     intent.outbound_key,
                     permanent_failure
                   )
                 end)
               )
               |> Task.await()

      # 3. Verify /jobs Routine Detail shows BOTH the pre-Signal failed entry AND deliveryWarning == true on the completed Signal run!
      assert {:ok, detail} = Pod.JobsBoard.routine_detail(actor, "cron", routine.id)

      signal_run = Enum.find(detail.runs, &(&1.id == ok_signal.id))
      assert signal_run != nil
      assert signal_run.status == "succeeded"
      assert signal_run.summary == "Prepared critical external alert."
      assert signal_run.deliveryWarning == true

      pre_signal_run = Enum.find(detail.runs, &(&1.id == to_string(failed_entry.id)))
      assert pre_signal_run != nil
      assert pre_signal_run.status == "failed"
      assert pre_signal_run.trigger == "scheduled"
      assert is_binary(pre_signal_run.error) and pre_signal_run.error != ""
    end
  end

  describe "Scenario 8: atomic Routine and binding creation" do
    test "deduplicates initial eventTriggers on retry and rolls back on failure" do
      %{principal: human} = Ankole.PrincipalsFixtures.human_fixture()
      actor = Ankole.PrincipalsFixtures.actor_fixture(human.uid)
      %{principal: agent} = agent_fixture(%{owner_principal_uid: human.uid})
      room_id = native_room_fixture(human.uid, agent.uid)

      assert {:ok, page} = Pages.create(actor, %{type: "applet"})
      reference = "applet://#{page.id}"

      request_id = Ecto.UUID.generate()

      payload = %{
        "mode" => "cron",
        "title" => "Idempotent Event Routine",
        "task" => "Process Connector events exactly once per binding.",
        "agentUID" => agent.uid,
        "conversationID" => room_id,
        "requestID" => request_id,
        "eventTriggers" => [
          %{
            "configRef" => reference,
            "name" => "Applet Webhook",
            "coalesce" => %{"enabled" => true, "window_ms" => 5_000}
          }
        ]
      }

      assert {:ok, card1} = Pod.JobsBoard.create(actor, payload)
      assert {:ok, card2} = Pod.JobsBoard.create(actor, payload)
      assert card1.id == card2.id
      "cron:" <> routine_id = card1.id

      assert [only_binding] = Signals.bindings_for_routine(routine_id, [])
      assert only_binding.config_ref == reference
      assert only_binding.agent_routine_id == routine_id
      assert <<_::48, 7::4, _::76>> = Ecto.UUID.dump!(only_binding.id)

      # Failed initial trigger rolls back the entire Routine instead of leaving a soft-deleted tombstone.
      failed_request_id = Ecto.UUID.generate()
      missing_ref = "applet://#{Ecto.UUID.generate()}"

      assert {:error, :invalid_job} =
               Pod.JobsBoard.create(actor, %{
                 "mode" => "cron",
                 "title" => "Atomic Rollback Routine",
                 "task" => "Should roll back when second trigger fails.",
                 "agentUID" => agent.uid,
                 "conversationID" => room_id,
                 "requestID" => failed_request_id,
                 "eventTriggers" => [
                   %{"configRef" => reference},
                   %{"configRef" => missing_ref}
                 ]
               })

      idempotency_key = "pod-cron:" <> failed_request_id

      assert Repo.one(from(r in AgentRoutine, where: r.idempotency_key == ^idempotency_key)) ==
               nil

      # Retrying the same requestID with corrected triggers now succeeds cleanly.
      assert {:ok, recovered_card} =
               Pod.JobsBoard.create(actor, %{
                 "mode" => "cron",
                 "title" => "Atomic Rollback Routine",
                 "task" => "Should succeed cleanly on retry.",
                 "agentUID" => agent.uid,
                 "conversationID" => room_id,
                 "requestID" => failed_request_id,
                 "eventTriggers" => [%{"configRef" => reference}]
               })

      assert String.starts_with?(recovered_card.id, "cron:")
    end
  end

  describe "Scenario 9: authoritative Routine task and delivery" do
    test "Cron fire reads Routine task and delivery over stale CronSchedule payload" do
      %{principal: human} = Ankole.PrincipalsFixtures.human_fixture()
      %{principal: agent} = agent_fixture(%{owner_principal_uid: human.uid})
      room_id = native_room_fixture(human.uid, agent.uid)
      room2_id = native_room_fixture(human.uid, agent.uid, grant?: false)

      assert {:ok, %{routine: routine, cron_schedule: nil}} =
               Schedule.create_routine(
                 %{
                   agent_uid: agent.uid,
                   owner_session_id: Ankole.Sessions.Key.conversation(room_id),
                   name: "authoritative-owner-routine",
                   idempotency_key: Ecto.UUID.generate(),
                   task: "Initial task v1",
                   delivery: %{"targets" => [%{"conversation_id" => room_id}]}
                 },
                 now: @base_time,
                 authorization: Ankole.Principals.WorkAccess.from_sender(human.uid)
               )

      assert {:ok, updated} =
               Schedule.update_routine(
                 routine.id,
                 %{
                   task: "Authoritative task v2",
                   delivery: %{"targets" => [%{"conversation_id" => room2_id}]},
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 600_000,
                     "anchor_at" => DateTime.to_iso8601(@base_time),
                     "timezone" => "UTC"
                   }
                 },
                 now: @base_time
               )

      assert updated.definition_version == 2

      [cron] =
        Schedule.schedules_by_owner_routines([routine.id])
        |> Map.fetch!(routine.id)

      assert cron.payload["task"] == "Authoritative task v2"

      # Simulate a stale payload on cron_schedules to prove Fire reads AgentRoutine as single source of truth.
      cron
      |> AshPostgres.DataLayer.to_ecto()
      |> Ecto.Changeset.change(%{payload: %{"task" => "STALE CRON TASK"}})
      |> Repo.update!()

      stub_driver(%{agent_uid: agent.uid, session_id: Ankole.Sessions.Key.routine(routine.id)})

      assert {:ok, %{signal: fired_signal}} = Schedule.fire_cron(cron.id, now: cron.next_fire_at)

      assert fired_signal.data["task"] == "Authoritative task v2"

      assert get_in(fired_signal.data, ["wake_payload", "payload", "task"]) ==
               "Authoritative task v2"

      assert get_in(fired_signal.data, ["wake_payload", "delivery", "targets"]) == [
               %{"conversation_id" => room2_id}
             ]
    end
  end

  describe "Scenario 10: cron tool on Hybrid and Event-only Routines" do
    test "isolates Hybrid Cron pause/remove and supports Event-only Routine actions" do
      %{principal: human} = Ankole.PrincipalsFixtures.human_fixture()
      actor = Ankole.PrincipalsFixtures.actor_fixture(human.uid)
      %{principal: agent} = agent_fixture(%{owner_principal_uid: human.uid})
      Ankole.ConversationsFixtures.grant_chat(human.uid, agent.uid)
      binding_fixture(agent.uid, "bot", :ignore)

      {:ok, %{signal: chat_signal}} =
        emit_entry(
          agent.uid,
          "bot",
          group_entry(%{text: "Manage our routines", explicit: true}),
          now: @base_time
        )

      {:ok, base_run} = Admission.admit(chat_signal, chat_signal)
      {:ok, context} = Ankole.Sessions.Context.resolve(base_run.agent_uid, base_run.session_id)
      {tools, _} = Ankole.Sessions.ToolCatalog.for_run(%{base_run | context: context})

      {:ok, response} =
        start_response_run(%{
          subject_uid: base_run.agent_uid,
          conversation_id: base_run.conversation.id
        })

      owner_run = %{base_run | context: context, tools: tools, model_response: response}

      reply_target =
        owner_run
        |> Ankole.Conversations.Route.snapshot()
        |> Map.take(~w(conversation_id binding_id binding_name provider_thread_id))

      assert {:ok, page} = Pages.create(actor, %{type: "applet"})
      reference = "applet://#{page.id}"

      # --- Part A: Hybrid Routine Cron pause/remove does NOT revoke active Connector Signals ---
      assert {:ok, %{routine: hybrid, cron_schedule: hybrid_cron}} =
               Schedule.create_routine(
                 %{
                   agent_uid: agent.uid,
                   owner_session_id: owner_run.session_id,
                   binding_name: reply_target["binding_name"],
                   name: "hybrid-ops-watcher",
                   idempotency_key: Ecto.UUID.generate(),
                   task: "Handle webhook incidents and run hourly sweep.",
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 3_600_000,
                     "anchor_at" => DateTime.to_iso8601(@base_time),
                     "timezone" => "UTC"
                   },
                   delivery: %{
                     "targets" => [reply_target]
                   }
                 },
                 now: @base_time,
                 authorization: Ankole.Principals.WorkAccess.from_sender(human.uid)
               )

      hybrid_session_id = Ankole.Sessions.Key.routine(hybrid.id)
      stub_driver(%{agent_uid: agent.uid, session_id: hybrid_session_id})

      assert {:ok, _binding} =
               Signals.put_event_binding(actor, %{
                 config_ref: reference,
                 agent_routine_id: hybrid.id
               })

      assert {:ok, %{signals: [queued_connector_sig]}} =
               Signals.emit(reference, %{
                 "id" => "hybrid-evt-1",
                 "type" => "incident.opened",
                 "subject" => "inc:1",
                 "data" => %{"severity" => "high"}
               })

      assert Repo.get!(Signal, queued_connector_sig.id).status == :queued

      paused_res =
        invoke_tool(
          owner_run,
          "cron",
          %{"action" => "pause", "name" => "hybrid-ops-watcher"},
          "c-pause-1"
        )

      refute paused_res.is_error, inspect(paused_res)
      assert Repo.get!(CronSchedule, hybrid_cron.id).status == :paused
      assert Repo.get!(AgentRoutine, hybrid.id).status == :active
      assert Repo.get!(Signal, queued_connector_sig.id).status == :queued

      resumed_res =
        invoke_tool(
          owner_run,
          "cron",
          %{"action" => "resume", "name" => "hybrid-ops-watcher"},
          "c-resume-1"
        )

      refute resumed_res.is_error, inspect(resumed_res)
      assert Repo.get!(CronSchedule, hybrid_cron.id).status == :active

      removed_cron_res =
        invoke_tool(
          owner_run,
          "cron",
          %{"action" => "remove", "name" => "hybrid-ops-watcher"},
          "c-remove-1"
        )

      refute removed_cron_res.is_error, inspect(removed_cron_res)
      assert Repo.get!(CronSchedule, hybrid_cron.id).status == :deleted

      # Hybrid Routine is now an active Event-only Routine; queued Connector Signal is still preserved!
      assert Repo.get!(AgentRoutine, hybrid.id).status == :active
      assert Repo.get!(Signal, queued_connector_sig.id).status == :queued

      # Pausing the now Event-only Routine pauses the Routine itself and revokes its unstarted Signal!
      paused_event_only_res =
        invoke_tool(
          owner_run,
          "cron",
          %{"action" => "pause", "name" => "hybrid-ops-watcher"},
          "c-pause-2"
        )

      refute paused_event_only_res.is_error, inspect(paused_event_only_res)
      assert Repo.get!(AgentRoutine, hybrid.id).status == :paused
      revoked_sig = Repo.get!(Signal, queued_connector_sig.id)
      assert revoked_sig.status == :dead_letter
      assert revoked_sig.dead_letter_reason == %{"reason" => "routine_paused"}

      # --- Part B: Pure Event-only Routine supports list, get, runs, update, run, resume, remove ---
      assert {:ok, page2} = Pages.create(actor, %{type: "applet"})
      reference2 = "applet://#{page2.id}"

      assert {:ok, %{routine: event_routine, cron_schedule: nil}} =
               Schedule.create_routine(
                 %{
                   agent_uid: agent.uid,
                   owner_session_id: owner_run.session_id,
                   binding_name: reply_target["binding_name"],
                   name: "pure-event-routine",
                   idempotency_key: Ecto.UUID.generate(),
                   task: "Triage incoming alerts.",
                   delivery: %{"targets" => [reply_target]}
                 },
                 now: @base_time,
                 authorization: Ankole.Principals.WorkAccess.from_sender(human.uid)
               )

      event_session_id = Ankole.Sessions.Key.routine(event_routine.id)
      stub_driver(%{agent_uid: agent.uid, session_id: event_session_id})

      assert {:ok, _} =
               Signals.put_event_binding(actor, %{
                 config_ref: reference2,
                 agent_routine_id: event_routine.id
               })

      assert {:ok, %{signals: [evt_sig]}} =
               Signals.emit(reference2, %{
                 "id" => "pure-evt-1",
                 "type" => "alert.fired",
                 "subject" => "alert:1",
                 "data" => %{"service" => "billing"}
               })

      finish_call = %{
        "type" => "function_call",
        "name" => "finish_scheduled",
        "call_id" => "finish_pure_evt",
        "arguments" =>
          Ankole.JSON.encode!(%{
            "outcome" => "silent_success",
            "reply" => nil,
            "summary" => "Triaged billing alert silently."
          })
      }

      assert {:ok, %{status: :completed}} =
               execute_scheduled_calls(
                 agent.uid,
                 evt_sig,
                 [finish_call],
                 :silent,
                 now: DateTime.add(evt_sig.available_at, 1, :second)
               )

      listed = invoke_tool(owner_run, "cron", %{"action" => "list"}, "c-list")
      refute listed.is_error, inspect(listed)
      pure_entry = Enum.find(listed.details["schedules"], &(&1["name"] == "pure-event-routine"))
      assert pure_entry != nil
      assert pure_entry["schedule"] == %{}
      assert pure_entry["status"] == "active"
      assert pure_entry["event_binding_count"] == 1

      got =
        invoke_tool(
          owner_run,
          "cron",
          %{"action" => "get", "name" => "pure-event-routine"},
          "c-get"
        )

      refute got.is_error, inspect(got)
      assert got.details["schedule"]["name"] == "pure-event-routine"
      assert got.details["schedule"]["event_binding_count"] == 1
      assert got.details["schedule"]["payload"]["task"] == "Triage incoming alerts."

      # Routine-origin turn without `name` resolves its owning Event-only Routine directly.
      origin_run = %{owner_run | session_id: event_session_id}
      origin_got = invoke_tool(origin_run, "cron", %{"action" => "get"}, "c-origin-get")
      refute origin_got.is_error, inspect(origin_got)
      assert origin_got.details["schedule"]["name"] == "pure-event-routine"

      runs_res =
        invoke_tool(
          owner_run,
          "cron",
          %{"action" => "runs", "name" => "pure-event-routine"},
          "c-runs"
        )

      refute runs_res.is_error, inspect(runs_res)
      assert [completed_run | _] = runs_res.details["runs"]
      assert completed_run["turn_summary"] == "Triaged billing alert silently."
      assert completed_run["turn_outcome"] == "silent"
      assert completed_run["trigger"] == "event"

      updated_res =
        invoke_tool(
          owner_run,
          "cron",
          %{
            "action" => "update",
            "name" => "pure-event-routine",
            "payload" => %{"task" => "Triage billing and auth alerts."}
          },
          "c-update"
        )

      refute updated_res.is_error, inspect(updated_res)
      assert Repo.get!(AgentRoutine, event_routine.id).task == "Triage billing and auth alerts."

      manual_res =
        invoke_tool(
          owner_run,
          "cron",
          %{"action" => "run", "name" => "pure-event-routine"},
          "c-manual-run"
        )

      refute manual_res.is_error, inspect(manual_res)
      assert manual_res.details["status"] == "scheduled"

      manual_sig =
        Repo.one!(
          from(s in Signal,
            where:
              s.agent_uid == ^agent.uid and s.session_id == ^event_session_id and
                s.type == "routine.manual_run" and s.status == :queued
          )
        )

      assert get_in(manual_sig.extensions, ["ankole_routine", "task"]) ==
               "Triage billing and auth alerts."

      removed_res =
        invoke_tool(
          owner_run,
          "cron",
          %{"action" => "remove", "name" => "pure-event-routine"},
          "c-remove-pure"
        )

      refute removed_res.is_error, inspect(removed_res)
      assert Repo.get!(AgentRoutine, event_routine.id).status == :deleted
      assert Repo.get!(Signal, manual_sig.id).status == :dead_letter

      # --- Part C: Hybrid Routine after finite Cron exhaustion still supports tool update/run/pause/resume ---
      assert {:ok, page3} = Pages.create(actor, %{type: "applet"})
      reference3 = "applet://#{page3.id}"

      assert {:ok, %{routine: bounded_hybrid, cron_schedule: bounded_cron}} =
               Schedule.create_routine(
                 %{
                   agent_uid: agent.uid,
                   owner_session_id: owner_run.session_id,
                   binding_name: reply_target["binding_name"],
                   name: "bounded-hybrid-routine",
                   idempotency_key: Ecto.UUID.generate(),
                   task: "Initial bounded sweep.",
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "anchor_at" => DateTime.to_iso8601(@base_time),
                     "occurrences" => %{"count" => 1}
                   },
                   delivery: %{"targets" => [reply_target]}
                 },
                 now: @base_time,
                 authorization: Ankole.Principals.WorkAccess.from_sender(human.uid)
               )

      bounded_session_id = Ankole.Sessions.Key.routine(bounded_hybrid.id)
      stub_driver(%{agent_uid: agent.uid, session_id: bounded_session_id})

      assert {:ok, _} =
               Signals.put_event_binding(actor, %{
                 config_ref: reference3,
                 agent_routine_id: bounded_hybrid.id
               })

      assert {:ok, %{status: :fired}} =
               Schedule.fire_cron(bounded_cron.id, now: bounded_cron.next_fire_at)

      assert Repo.get!(CronSchedule, bounded_cron.id).status == :completed
      assert Repo.get!(AgentRoutine, bounded_hybrid.id).status == :active

      post_complete_update =
        invoke_tool(
          owner_run,
          "cron",
          %{
            "action" => "update",
            "name" => "bounded-hybrid-routine",
            "payload" => %{"task" => "Updated post-exhaustion sweep."}
          },
          "c-bounded-update"
        )

      refute post_complete_update.is_error, inspect(post_complete_update)
      assert Repo.get!(AgentRoutine, bounded_hybrid.id).task == "Updated post-exhaustion sweep."

      post_complete_run =
        invoke_tool(
          owner_run,
          "cron",
          %{"action" => "run", "name" => "bounded-hybrid-routine"},
          "c-bounded-run"
        )

      refute post_complete_run.is_error, inspect(post_complete_run)
      assert post_complete_run.details["status"] == "scheduled"

      bounded_manual_sig =
        Repo.one!(
          from(s in Signal,
            where:
              s.agent_uid == ^agent.uid and s.session_id == ^bounded_session_id and
                s.type == "routine.manual_run" and s.status == :queued
          )
        )

      assert get_in(bounded_manual_sig.extensions, ["ankole_routine", "task"]) ==
               "Updated post-exhaustion sweep."

      post_complete_pause =
        invoke_tool(
          owner_run,
          "cron",
          %{"action" => "pause", "name" => "bounded-hybrid-routine"},
          "c-bounded-pause"
        )

      refute post_complete_pause.is_error, inspect(post_complete_pause)
      assert Repo.get!(AgentRoutine, bounded_hybrid.id).status == :paused

      post_complete_resume =
        invoke_tool(
          owner_run,
          "cron",
          %{"action" => "resume", "name" => "bounded-hybrid-routine"},
          "c-bounded-resume"
        )

      refute post_complete_resume.is_error, inspect(post_complete_resume)
      assert Repo.get!(AgentRoutine, bounded_hybrid.id).status == :active
    end
  end

  describe "Scenario 11: Agent <-> Action round-trip Routine lifecycle" do
    test "detaching to Action and reattaching to Agent mints a fresh active Routine that fires cleanly" do
      %{principal: human} = Ankole.PrincipalsFixtures.human_fixture()
      %{principal: agent} = agent_fixture(%{owner_principal_uid: human.uid})
      room_id = native_room_fixture(human.uid, agent.uid)
      action_job = Ankole.WorkFixtures.applet_job(agent.uid)

      assert {:ok, %{cron_schedule: cron}} =
               Schedule.create_cron_schedule(
                 %{
                   agent_uid: agent.uid,
                   owner_session_id: Ankole.Sessions.Key.conversation(room_id),
                   name: "roundtrip-agent-action-cron",
                   idempotency_key: "roundtrip-key-" <> Ecto.UUID.generate(),
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "anchor_at" => DateTime.to_iso8601(@base_time)
                   },
                   payload: %{"task" => "Agent task v1"},
                   delivery: %{"targets" => [%{"conversation_id" => room_id}]}
                 },
                 now: @base_time,
                 authorization: Ankole.Principals.WorkAccess.from_sender(human.uid)
               )

      initial_routine_id = cron.owner_routine_id
      assert is_binary(initial_routine_id)
      assert Repo.get!(AgentRoutine, initial_routine_id).status == :active

      # Detach to Action: old Routine becomes :deleted and owner_routine_id is cleared.
      assert {:ok, action_cron} =
               Schedule.update_cron_schedule(
                 cron.id,
                 %{"automation_job_id" => action_job.id},
                 now: @base_time
               )

      assert is_nil(action_cron.owner_routine_id)
      assert Repo.get!(AgentRoutine, initial_routine_id).status == :deleted

      # Reattach back to Agent: must bind to a fresh active Routine, NOT the deleted initial Routine!
      assert {:ok, reattached_cron} =
               Schedule.update_cron_schedule(
                 cron.id,
                 %{
                   "automation_job_id" => nil,
                   "payload" => %{"task" => "Reattached Agent task v2"}
                 },
                 now: @base_time
               )

      reattached_routine_id = reattached_cron.owner_routine_id
      assert is_binary(reattached_routine_id)
      assert reattached_routine_id != initial_routine_id

      reattached_routine = Repo.get!(AgentRoutine, reattached_routine_id)
      assert reattached_routine.status == :active
      assert reattached_routine.task == "Reattached Agent task v2"

      stub_driver(%{
        agent_uid: agent.uid,
        session_id: Ankole.Sessions.Key.routine(reattached_routine_id)
      })

      assert {:ok, %{status: :fired, signal: fired_signal}} =
               Schedule.fire_cron(reattached_cron.id, now: reattached_cron.next_fire_at)

      assert fired_signal.session_id == Ankole.Sessions.Key.routine(reattached_routine_id)
      assert fired_signal.data["task"] == "Reattached Agent task v2"
    end
  end

  defp execute_scheduled_calls(agent_uid, %Signal{} = event, calls, terminal_outcome, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    key = %{agent_uid: agent_uid, session_id: event.session_id}

    assert {:ok, run} = Admission.admit(key, event, now: now)
    assert :ok = Presentation.start(run, self())
    assert {:ok, {:preparing, run}} = Model.prepare(run)

    response = complete_response_items(agent_uid, event, calls)
    run = %{run | model_response: response, calls: calls, round_calls: calls}

    results =
      Map.new(calls, fn call ->
        assert {:ok, tool, args} = Tools.prepare(run, call)
        result = Tools.execute(run, call, tool, args)

        refute result.is_error,
               "Expected tool #{call["name"]} to succeed, got: #{inspect(result)}"

        {call["call_id"], result}
      end)

    run_with_results = %{run | results: results}
    assert {:ok, journal} = Run.record_round(run_with_results)
    assert {:ok, {_state, restored}} = Run.restore(run_with_results)

    Run.finalize(
      %{restored | event: Repo.get!(Signal, event.id), anchor: journal.message.id},
      terminal_outcome
    )
  end

  defp complete_response_items(subject_uid, event, items) do
    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(
        subject_uid,
        event.session_id,
        kind: :routine
      )

    {:ok, response_run} =
      start_response_run(%{
        subject_uid: subject_uid,
        conversation_id: conversation.id,
        request_items: [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "execute routine turn"}]
          }
        ],
        metadata: %{"request_metadata" => %{"signal_id" => event.id}}
      })

    assert {:ok, final} =
             Ankole.AIGateway.ResponseCommit.commit_complete(response_run, items, %{})

    final
  end

  defp native_room_fixture(human_uid, agent_uid, opts \\ []) do
    if Keyword.get(opts, :grant?, true) do
      Ankole.ConversationsFixtures.grant_chat(human_uid, agent_uid)
    end

    conversation_id = Ecto.UUID.generate()

    stub_driver(%{
      agent_uid: agent_uid,
      session_id: Ankole.Sessions.Key.conversation(conversation_id)
    })

    assert {:ok, native} =
             Ankole.ConversationsFixtures.create(human_uid, %{
               conversation_id: conversation_id,
               message_id: Ecto.UUID.generate(),
               agent_uid: agent_uid,
               text: "Create routine room"
             })

    native.conversation.id
  end

  defp invoke_tool(run, name, args, id) do
    call = %{
      "type" => "function_call",
      "name" => name,
      "call_id" => id,
      "arguments" => Ankole.JSON.encode!(args)
    }

    assert {:ok, tool, normalized} = Tools.prepare(run, call)
    Tools.execute(run, call, tool, normalized)
  end
end
