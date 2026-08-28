defmodule Ankole.ScheduleTest do
  use Ankole.DataCase, async: false

  alias Ankole.AIGateway.Conversations

  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SignalsGateway.ActorRuntime.WorkerRouteAuth
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.SignalsGateway.ActorRuntime.Transport.Broker
  alias Ankole.PluginFixtures.MockSignalProviderPlugin
  alias Ankole.PluginFixtures.MockSignalProvider.Inbound, as: MockInbound
  alias Ankole.Plugins.Spec
  alias Ankole.Repo
  alias Ankole.Schedule
  alias Ankole.Schedule.Schemas.CronSchedule
  alias Ankole.Schedule.Schemas.ScheduledEvent
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.AdapterContext
  alias Ankole.SignalsGateway.InboundBatch
  alias Ankole.SignalsGateway.Ingress
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.Entry

  import Ankole.SignalsGateway.ActorRuntimeCase,
    only: [
      complete_actor_event: 4,
      process_ready_events_once: 1,
      turn_proto_ref: 1,
      turn_accepted_payload: 1,
      commit_turn_completion: 3,
      complete_turn_noop: 2,
      turn_start_payload!: 1,
      decoded_request_context: 1
    ]

  import Ankole.SignalsGatewayFixtures, only: [outbox_adapter: 2]

  @base_time DateTime.utc_now(:microsecond)
  @long_lease_seconds 604_800

  setup :use_mock_signal_provider_plugin

  describe "durable schedule domain" do
    test "model projections reduce operator errors to stable schedule reasons" do
      internal_id = "019f0000-0000-7000-8000-000000000001"

      event = %ScheduledEvent{
        id: 1000,
        kind: "check_back_later",
        status: "failed",
        wake_payload: %{},
        last_fire_error: %{
          "reason" => "provider request #{internal_id} failed",
          "actor_event_id" => internal_id
        }
      }

      projection = Schedule.event_model_projection(event)

      assert projection["last_error"] == %{"reason" => "schedule_fire_failed"}
      refute inspect(projection) =~ internal_id

      known = %{event | last_fire_error: %{"reason" => ":cron_schedule_not_active"}}

      assert Schedule.event_model_projection(known)["last_error"] == %{
               "reason" => "cron_schedule_not_active"
             }
    end

    test "check_back_later creates one wake edge and fires one actor event idempotently" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      due_at = DateTime.add(@base_time, 5, :minute)

      attrs =
        checkback_attrs(agent.uid,
          schedule: %{"at" => DateTime.to_iso8601(due_at), "timezone" => "Etc/UTC"}
        )

      assert {:ok, %{status: :scheduled, scheduled_event: event}} =
               Schedule.create_check_back_later(attrs, now: @base_time)

      assert event.due_at == due_at
      assert event.source_entry_id == "msg-source"
      assert event.wake_payload["quiet_success"] == false

      assert {:ok, %{status: :already_scheduled, scheduled_event: duplicate}} =
               Schedule.create_check_back_later(attrs, now: @base_time)

      assert duplicate.id == event.id

      assert {:ok, %{status: :fired, actor_event: input}} =
               Schedule.fire_due_event(event.id, now: due_at)

      assert input.type == "check_back_later.wakeup"
      assert input.source_event_id == "check_back_later:#{event.id}:wakeup"
      assert get_in(input.payload, ["data", "wake_payload", "check"]) == "Check the incident."

      assert {:ok, %{status: :noop}} = Schedule.fire_due_event(event.id, now: due_at)
      assert Repo.aggregate(ActorEvent, :count) == 1
    end

    test "updating a checkback preserves its due time but replaces stale wakeup instructions" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      due_at = DateTime.add(@base_time, 5, :minute)

      assert {:ok, %{scheduled_event: original}} =
               Schedule.create_check_back_later(
                 checkback_attrs(agent.uid,
                   check: "Write a professional PDF, preferably 6–12 pages.",
                   schedule: %{"at" => DateTime.to_iso8601(due_at), "timezone" => "Etc/UTC"}
                 ),
                 now: @base_time
               )

      update_attrs =
        agent.uid
        |> checkback_attrs(
          tool_call_id: "tool-check-update-1",
          idempotency_key: "checkback-update-1",
          check: "Let the information value and evidence density determine the PDF length.",
          context_summary: "The user removed the 6–12 page constraint."
        )
        |> Map.delete("schedule")

      assert {:ok,
              %{
                status: :updated,
                previous_scheduled_event: cancelled,
                scheduled_event: replacement
              }} =
               Schedule.update_checkback(original.id, update_attrs,
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert replacement.id != original.id
      assert replacement.due_at == due_at

      assert replacement.wake_payload["check"] ==
               "Let the information value and evidence density determine the PDF length."

      assert replacement.wake_payload["context_summary"] ==
               "The user removed the 6–12 page constraint."

      assert replacement.source_provenance["replaces_scheduled_event_id"] == original.id
      assert cancelled.status == "cancelled"

      assert cancelled.last_fire_error == %{
               "reason" => "checkback_replaced",
               "replacement_scheduled_event_id" => replacement.id
             }

      assert {:ok, %{status: :already_updated, scheduled_event: retried}} =
               Schedule.update_checkback(original.id, update_attrs,
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert retried.id == replacement.id
      assert {:ok, %{status: :noop}} = Schedule.fire_due_event(original.id, now: due_at)

      assert {:ok, %{status: :fired, actor_event: wakeup}} =
               Schedule.fire_due_event(replacement.id, now: due_at)

      assert get_in(wakeup.payload, ["data", "wake_payload", "check"]) ==
               "Let the information value and evidence density determine the PDF length."

      assert Repo.aggregate(ActorEvent, :count) == 1
    end

    test "later updates and cancellation follow a replaced checkback id to the current event" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      due_at = DateTime.add(@base_time, 5, :minute)

      assert {:ok, %{scheduled_event: original}} =
               Schedule.create_check_back_later(
                 checkback_attrs(agent.uid,
                   schedule: %{"at" => DateTime.to_iso8601(due_at), "timezone" => "Etc/UTC"}
                 ),
                 now: @base_time
               )

      first_update =
        agent.uid
        |> checkback_attrs(
          tool_call_id: "tool-check-update-chain-1",
          idempotency_key: "checkback-update-chain-1",
          check: "Use the first correction."
        )
        |> Map.delete("schedule")

      assert {:ok, %{scheduled_event: first_replacement}} =
               Schedule.update_checkback(original.id, first_update,
                 now: DateTime.add(@base_time, 1, :second)
               )

      second_update =
        agent.uid
        |> checkback_attrs(
          tool_call_id: "tool-check-update-chain-2",
          idempotency_key: "checkback-update-chain-2",
          check: "Use the latest correction."
        )
        |> Map.delete("schedule")

      assert {:ok, %{previous_scheduled_event: previous, scheduled_event: current}} =
               Schedule.update_checkback(original.id, second_update,
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert previous.id == first_replacement.id
      assert current.wake_payload["check"] == "Use the latest correction."

      assert {:ok, cancelled} =
               Schedule.cancel_checkback(original.id,
                 now: DateTime.add(@base_time, 3, :second)
               )

      assert cancelled.id == current.id
      assert cancelled.status == "cancelled"
      assert Schedule.list_pending_checkbacks(agent.uid, original.session_id) == []
      assert {:ok, %{status: :noop}} = Schedule.fire_due_event(original.id, now: due_at)
      assert {:ok, %{status: :noop}} = Schedule.fire_due_event(first_replacement.id, now: due_at)
      assert {:ok, %{status: :noop}} = Schedule.fire_due_event(current.id, now: due_at)
      assert Repo.aggregate(ActorEvent, :count) == 0
    end

    test "fire failures persist diagnostics and mark final attempt failed" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      due_at = DateTime.add(@base_time, 5, :minute)

      assert {:ok, %{status: :scheduled, scheduled_event: event}} =
               Schedule.create_check_back_later(
                 checkback_attrs(agent.uid,
                   schedule: %{"at" => DateTime.to_iso8601(due_at), "timezone" => "Etc/UTC"}
                 ),
                 now: @base_time
               )

      ScheduledEvent
      |> where([scheduled_event], scheduled_event.id == ^event.id)
      |> Repo.update_all(set: [binding_name: ""])

      assert {:error, %Ecto.Changeset{}} =
               Schedule.fire_due_event(event.id, now: due_at, attempt: 3, max_attempts: 10)

      retried = Repo.get!(ScheduledEvent, event.id)
      assert retried.status == "scheduled"
      assert retried.fire_attempts == 3
      assert retried.last_fire_error["reason"] =~ "binding_name"

      assert {:error, %Ecto.Changeset{}} =
               Schedule.fire_due_event(event.id, now: due_at, attempt: 10, max_attempts: 10)

      failed = Repo.get!(ScheduledEvent, event.id)
      assert failed.status == "failed"
      assert failed.fire_attempts == 10
      assert failed.last_fire_error["reason"] =~ "binding_name"
    end

    test "FireScheduledEvent Oban job fires a due scheduled event" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      due_at = DateTime.add(DateTime.utc_now(:microsecond), -60, :second)

      assert {:ok, %{status: :scheduled, scheduled_event: event}} =
               Schedule.create_check_back_later(
                 checkback_attrs(agent.uid,
                   idempotency_key: "checkback-oban-fire",
                   schedule: %{"at" => DateTime.to_iso8601(due_at), "timezone" => "Etc/UTC"}
                 ),
                 now: DateTime.add(due_at, -60, :second)
               )

      assert :ok =
               perform_job(Ankole.SignalsGateway.ActorRuntime.Jobs.FireScheduledEvent, %{
                 "scheduled_event_id" => event.id
               })

      fired = Repo.get!(ScheduledEvent, event.id)
      assert fired.status == "fired"
      assert %DateTime{} = fired.fired_at

      assert %ActorEvent{type: "check_back_later.wakeup"} =
               Repo.get!(ActorEvent, fired.actor_event_id)
    end

    test "cron fire coalesces missed backlog and carries configured delivery route" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      first_slot = DateTime.add(@base_time, 1, :minute)
      late_fire = DateTime.add(@base_time, 10, :minute)
      origin_ai_message = ai_message_fixture(agent.uid)

      assert {:ok, %{status: :created, cron_schedule: schedule}} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid,
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "timezone" => "Etc/UTC",
                     "anchor_at" => DateTime.to_iso8601(first_slot)
                   }
                 ),
                 now: @base_time,
                 created_by: %{
                   "kind" => "test",
                   "origin_ai_message_id" => origin_ai_message.id
                 }
               )

      assert [event] = Schedule.list_cron_runs(schedule.id, 10)

      assert schedule.delivery == %{
               "targets" => [
                 %{
                   "binding_name" => "bot",
                   "signal_channel_id" => "mock:chat:schedule",
                   "provider_thread_id" => "thread-schedule"
                 }
               ]
             }

      assert event.due_at == first_slot
      assert event.signal_channel_id == "mock:chat:schedule"
      assert event.provider_thread_id == "thread-schedule"
      assert event.origin_ai_message_id == origin_ai_message.id

      assert {:ok, %{status: :fired, actor_event: input}} =
               Schedule.fire_due_event(event.id, now: late_fire)

      assert input.type == "cron.fire"
      assert input.session_id == Schedule.cron_execution_session_id(schedule.id)
      assert input.session_id != schedule.owner_session_id
      assert input.signal_channel_id == "mock:chat:schedule"
      assert input.source_entry_id == nil

      reloaded = Schedule.get_cron_schedule(schedule.id) |> elem(1)
      assert reloaded.last_fire_at == first_slot
      assert reloaded.next_fire_at == DateTime.add(@base_time, 11, :minute)

      scheduled_events =
        schedule.id
        |> Schedule.list_cron_runs(10)
        |> Enum.filter(&(&1.status == "scheduled"))

      assert length(scheduled_events) == 1
      assert hd(scheduled_events).cron_fire_slot_at == DateTime.add(@base_time, 11, :minute)
      assert hd(scheduled_events).origin_ai_message_id == origin_ai_message.id
    end

    test "cron schedules require explicit delivery and paused schedules do not advertise a live next fire" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      first_slot = DateTime.add(@base_time, 1, :minute)

      assert {:error, :cron_delivery_route_required} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid,
                   delivery: nil,
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "timezone" => "Etc/UTC",
                     "anchor_at" => DateTime.to_iso8601(first_slot)
                   }
                 ),
                 now: @base_time
               )

      assert {:ok, %{status: :created, cron_schedule: paused}} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid,
                   status: "paused",
                   idempotency_key: "paused-cron-key",
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "timezone" => "Etc/UTC",
                     "anchor_at" => DateTime.to_iso8601(first_slot)
                   }
                 ),
                 now: @base_time
               )

      assert paused.status == "paused"
      assert paused.next_fire_at == nil
      assert Schedule.list_cron_runs(paused.id, 10) == []
    end

    test "cron delivery keeps targets and quiet success across independent updates" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      first_slot = DateTime.add(@base_time, 1, :minute)

      targets = [
        %{
          "binding_name" => "bot",
          "signal_channel_id" => "mock:chat:schedule",
          "provider_thread_id" => "thread-schedule"
        },
        %{
          "binding_name" => "secondary-bot",
          "signal_channel_id" => "mock:chat:secondary"
        }
      ]

      assert {:ok, %{cron_schedule: schedule}} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid,
                   name: "multi-target-delivery",
                   idempotency_key: "multi-target-delivery",
                   delivery: %{"targets" => targets},
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "anchor_at" => DateTime.to_iso8601(first_slot)
                   }
                 ),
                 now: @base_time
               )

      assert schedule.delivery == %{"targets" => targets}

      assert {:ok, updated} =
               Schedule.update_cron_schedule(
                 schedule.id,
                 %{"delivery" => %{"quiet_success" => true}},
                 now: @base_time
               )

      assert updated.delivery == %{"targets" => targets, "quiet_success" => true}

      replacement_targets = [
        hd(targets),
        %{
          "binding_name" => "archive-bot",
          "signal_channel_id" => "mock:chat:archive"
        }
      ]

      assert {:ok, route_updated} =
               Schedule.update_cron_schedule(
                 schedule.id,
                 %{"delivery" => %{"targets" => replacement_targets}},
                 now: @base_time
               )

      assert route_updated.delivery == %{
               "targets" => replacement_targets,
               "quiet_success" => true
             }

      assert {:ok, explicitly_noisy} =
               Schedule.update_cron_schedule(
                 schedule.id,
                 %{
                   "delivery" => %{
                     "targets" => targets,
                     "quiet_success" => false
                   }
                 },
                 now: @base_time
               )

      assert explicitly_noisy.delivery == %{"targets" => targets, "quiet_success" => false}

      assert {:error, :duplicate_cron_delivery_target} =
               Schedule.update_cron_schedule(
                 schedule.id,
                 %{"delivery" => %{"targets" => [hd(targets), hd(targets)]}},
                 now: @base_time
               )

      assert {:error, :cron_primary_delivery_binding_mismatch} =
               Schedule.update_cron_schedule(
                 schedule.id,
                 %{"delivery" => %{"targets" => Enum.reverse(targets)}},
                 now: @base_time
               )
    end

    test "a scalar delivery route is rejected" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()

      assert {:error, :cron_delivery_route_required} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid,
                   name: "invalid-target-list",
                   idempotency_key: "invalid-target-list",
                   delivery: %{"signal_channel_id" => "mock:chat:legacy"}
                 ),
                 now: @base_time
               )
    end

    test "payload updates keep the live slot and update its event snapshot in place" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      first_slot = DateTime.add(@base_time, 5, :minute)

      assert {:ok, %{cron_schedule: schedule}} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid,
                   name: "snapshot-update",
                   idempotency_key: "snapshot-update",
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "anchor_at" => DateTime.to_iso8601(first_slot)
                   }
                 ),
                 now: @base_time
               )

      [original] = Schedule.list_cron_runs(schedule.id, 10)

      assert {:ok, updated} =
               Schedule.update_cron_schedule(
                 schedule.id,
                 %{
                   "name" => "snapshot-update-renamed",
                   "payload" => %{"task" => "updated digest"}
                 },
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert updated.next_fire_at == first_slot
      assert updated.name == "snapshot-update-renamed"
      assert [current] = Schedule.list_cron_runs(schedule.id, 10)
      assert current.id == original.id
      assert current.status == "scheduled"
      assert current.idempotency_key == original.idempotency_key
      assert current.wake_payload["cron_schedule_name"] == "snapshot-update-renamed"
      assert current.wake_payload["payload"] == %{"task" => "updated digest"}
    end

    test "pause and resume replace a cancelled event in the same deterministic slot" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      first_slot = DateTime.add(@base_time, 5, :minute)

      assert {:ok, %{cron_schedule: schedule}} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid,
                   name: "same-slot-resume",
                   idempotency_key: "same-slot-resume",
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "anchor_at" => DateTime.to_iso8601(first_slot)
                   }
                 ),
                 now: @base_time
               )

      [original] = Schedule.list_cron_runs(schedule.id, 10)

      assert {:ok, paused} =
               Schedule.pause_cron_schedule(schedule.id,
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert paused.status == "paused"
      assert paused.next_fire_at == nil
      assert Repo.get!(ScheduledEvent, original.id).status == "cancelled"

      assert {:ok, resumed} =
               Schedule.resume_cron_schedule(schedule.id,
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert resumed.status == "active"
      assert resumed.next_fire_at == first_slot

      assert [replacement, cancelled] = Schedule.list_cron_runs(schedule.id, 10)
      assert replacement.status == "scheduled"
      assert replacement.id != original.id
      assert replacement.cron_fire_slot_at == first_slot
      assert cancelled.id == original.id
      assert cancelled.status == "cancelled"

      assert {:ok, active_noop} =
               Schedule.resume_cron_schedule(schedule.id,
                 now: DateTime.add(@base_time, 3, :second)
               )

      assert active_noop.next_fire_at == first_slot

      assert Enum.count(Schedule.list_cron_runs(schedule.id, 10), &(&1.status == "scheduled")) ==
               1
    end

    test "a cron rule can move away from and return to a cancelled historical slot" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      original_slot = DateTime.add(@base_time, 5, :minute)
      moved_slot = DateTime.add(@base_time, 10, :minute)

      assert {:ok, %{cron_schedule: schedule}} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid,
                   name: "slot-round-trip",
                   idempotency_key: "slot-round-trip",
                   schedule: every_schedule(original_slot)
                 ),
                 now: @base_time
               )

      assert {:ok, moved} =
               Schedule.update_cron_schedule(
                 schedule.id,
                 %{"schedule" => every_schedule(moved_slot)},
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert moved.next_fire_at == moved_slot

      assert {:ok, restored} =
               Schedule.update_cron_schedule(
                 schedule.id,
                 %{"schedule" => every_schedule(original_slot)},
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert restored.next_fire_at == original_slot

      runs = Schedule.list_cron_runs(schedule.id, 10)
      assert Enum.count(runs, &(&1.status == "scheduled")) == 1
      assert Enum.find(runs, &(&1.status == "scheduled")).cron_fire_slot_at == original_slot
      assert Enum.count(runs, &(&1.status == "cancelled")) == 2
    end

    test "manual cron run replay uses the caller tool id and different calls stay distinct" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()

      assert {:ok, %{cron_schedule: schedule}} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid,
                   status: "paused",
                   name: "manual-idempotency",
                   idempotency_key: "manual-idempotency"
                 ),
                 now: @base_time
               )

      assert {:ok, %{status: :scheduled, scheduled_event: first}} =
               Schedule.run_cron_schedule(schedule.id,
                 now: @base_time,
                 tool_call_id: "call-manual-1"
               )

      assert {:ok, %{status: :already_scheduled, scheduled_event: replayed}} =
               Schedule.run_cron_schedule(schedule.id,
                 now: DateTime.add(@base_time, 1, :second),
                 tool_call_id: "call-manual-1"
               )

      assert replayed.id == first.id

      assert {:ok, %{status: :scheduled, scheduled_event: second}} =
               Schedule.run_cron_schedule(schedule.id,
                 now: @base_time,
                 tool_call_id: "call-manual-2"
               )

      assert second.id != first.id
      assert first.cron_fire_slot_at == second.cron_fire_slot_at

      assert {:ok, %{actor_event: first_input}} =
               Schedule.fire_due_event(first.id, now: @base_time)

      assert {:ok, %{actor_event: second_input}} =
               Schedule.fire_due_event(second.id, now: @base_time)

      assert first_input.source_event_id == "cron-manual:#{schedule.id}:call-manual-1"
      assert second_input.source_event_id == "cron-manual:#{schedule.id}:call-manual-2"
    end

    test "terminal recurring fire failure schedules the next slot" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      first_slot = DateTime.add(@base_time, 1, :minute)

      assert {:ok, %{cron_schedule: schedule}} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid,
                   name: "terminal-failure-continues",
                   idempotency_key: "terminal-failure-continues",
                   schedule: every_schedule(first_slot)
                 ),
                 now: @base_time
               )

      [event] = Schedule.list_cron_runs(schedule.id, 10)

      ScheduledEvent
      |> where([scheduled_event], scheduled_event.id == ^event.id)
      |> Repo.update_all(set: [binding_name: ""])

      assert {:error, %Ecto.Changeset{}} =
               Schedule.fire_due_event(event.id,
                 now: first_slot,
                 attempt: 10,
                 max_attempts: 10
               )

      assert Repo.get!(ScheduledEvent, event.id).status == "failed"

      assert {:ok, advanced} = Schedule.get_cron_schedule(schedule.id)
      assert advanced.next_fire_at == DateTime.add(first_slot, 1, :minute)

      assert [next, failed] = Schedule.list_cron_runs(schedule.id, 10)
      assert next.status == "scheduled"
      assert next.cron_fire_slot_at == DateTime.add(first_slot, 1, :minute)
      assert failed.id == event.id
      assert failed.status == "failed"
    end

    test "a count bound completes the schedule after its due slots, ignoring manual runs" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      first_slot = DateTime.add(@base_time, 1, :minute)

      assert {:ok, %{cron_schedule: schedule}} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid,
                   name: "count-bounded",
                   idempotency_key: "count-bounded",
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "anchor_at" => DateTime.to_iso8601(first_slot),
                     "occurrences" => %{"count" => 2}
                   }
                 ),
                 now: @base_time
               )

      assert schedule.schedule["occurrences"] == %{"count" => 2}

      # A manual run is outside the recurrence and must not spend the budget.
      assert {:ok, %{status: :scheduled, scheduled_event: manual}} =
               Schedule.run_cron_schedule(schedule.id, tool_call_id: "manual-1", now: @base_time)

      assert {:ok, %{status: :fired}} = Schedule.fire_due_event(manual.id, now: @base_time)

      [event] =
        for run <- Schedule.list_cron_runs(schedule.id, 10), run.status == "scheduled", do: run

      assert {:ok, %{status: :fired}} = Schedule.fire_due_event(event.id, now: first_slot)

      assert {:ok, after_first} = Schedule.get_cron_schedule(schedule.id)
      assert after_first.status == "active"
      second_slot = DateTime.add(first_slot, 1, :minute)
      assert after_first.next_fire_at == second_slot

      [second] =
        for run <- Schedule.list_cron_runs(schedule.id, 10), run.status == "scheduled", do: run

      assert {:ok, %{status: :fired}} = Schedule.fire_due_event(second.id, now: second_slot)

      assert {:ok, completed} = Schedule.get_cron_schedule(schedule.id)
      assert completed.status == "completed"
      assert completed.next_fire_at == nil

      assert [] ==
               for(
                 run <- Schedule.list_cron_runs(schedule.id, 10),
                 run.status == "scheduled",
                 do: run
               )

      # Terminal state: only removal remains available.
      assert {:error, :cron_schedule_completed} =
               Schedule.pause_cron_schedule(schedule.id, now: second_slot)

      assert {:error, :cron_schedule_completed} =
               Schedule.resume_cron_schedule(schedule.id, now: second_slot)

      assert {:error, :cron_schedule_completed} =
               Schedule.run_cron_schedule(schedule.id, tool_call_id: "manual-2", now: second_slot)

      assert {:error, :cron_schedule_completed} =
               Schedule.update_cron_schedule(schedule.id, %{"payload" => %{"task" => "late"}},
                 now: second_slot
               )

      assert {:ok, removed} = Schedule.remove_cron_schedule(schedule.id, now: second_slot)
      assert removed.status == "deleted"
    end

    test "a count bound treats a terminally failed slot as consumed" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      first_slot = DateTime.add(@base_time, 1, :minute)

      assert {:ok, %{cron_schedule: schedule}} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid,
                   name: "count-bounded-failure",
                   idempotency_key: "count-bounded-failure",
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "anchor_at" => DateTime.to_iso8601(first_slot),
                     "occurrences" => %{"count" => 1}
                   }
                 ),
                 now: @base_time
               )

      [event] = Schedule.list_cron_runs(schedule.id, 10)

      ScheduledEvent
      |> where([scheduled_event], scheduled_event.id == ^event.id)
      |> Repo.update_all(set: [binding_name: ""])

      assert {:error, %Ecto.Changeset{}} =
               Schedule.fire_due_event(event.id,
                 now: first_slot,
                 attempt: 10,
                 max_attempts: 10
               )

      assert Repo.get!(ScheduledEvent, event.id).status == "failed"

      assert {:ok, completed} = Schedule.get_cron_schedule(schedule.id)
      assert completed.status == "completed"
      assert completed.next_fire_at == nil
    end

    test "an until bound stops after the cutoff and rejects a cutoff before the first occurrence" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      first_slot = DateTime.add(@base_time, 1, :minute)
      cutoff = DateTime.add(@base_time, 90, :second)

      assert {:error, :schedule_occurrences_exhausted} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid,
                   name: "until-before-first",
                   idempotency_key: "until-before-first",
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "anchor_at" => DateTime.to_iso8601(first_slot),
                     "occurrences" => %{"until" => DateTime.to_iso8601(@base_time)}
                   }
                 ),
                 now: @base_time
               )

      assert {:ok, %{cron_schedule: schedule}} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid,
                   name: "until-bounded",
                   idempotency_key: "until-bounded",
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "anchor_at" => DateTime.to_iso8601(first_slot),
                     "occurrences" => %{"until" => DateTime.to_iso8601(cutoff)}
                   }
                 ),
                 now: @base_time
               )

      [event] = Schedule.list_cron_runs(schedule.id, 10)
      assert {:ok, %{status: :fired}} = Schedule.fire_due_event(event.id, now: first_slot)

      assert {:ok, completed} = Schedule.get_cron_schedule(schedule.id)
      assert completed.status == "completed"
      assert completed.next_fire_at == nil
    end

    test "resume completes a paused schedule whose bound ran out while paused" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      first_slot = DateTime.add(@base_time, 1, :minute)
      cutoff = DateTime.add(@base_time, 90, :second)
      after_cutoff = DateTime.add(@base_time, 10, :minute)

      assert {:ok, %{cron_schedule: schedule}} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid,
                   name: "resume-past-until",
                   idempotency_key: "resume-past-until",
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "anchor_at" => DateTime.to_iso8601(first_slot),
                     "occurrences" => %{"until" => DateTime.to_iso8601(cutoff)}
                   }
                 ),
                 now: @base_time
               )

      assert {:ok, paused} = Schedule.pause_cron_schedule(schedule.id, now: @base_time)
      assert paused.status == "paused"

      assert {:ok, resumed} = Schedule.resume_cron_schedule(schedule.id, now: after_cutoff)
      assert resumed.status == "completed"
      assert resumed.next_fire_at == nil
    end

    test "an update whose new bound is already spent is rejected" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      first_slot = DateTime.add(@base_time, 1, :minute)

      assert {:ok, %{cron_schedule: schedule}} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid,
                   name: "update-spent-bound",
                   idempotency_key: "update-spent-bound",
                   schedule: every_schedule(first_slot)
                 ),
                 now: @base_time
               )

      [event] = Schedule.list_cron_runs(schedule.id, 10)
      assert {:ok, %{status: :fired}} = Schedule.fire_due_event(event.id, now: first_slot)

      assert {:error, :schedule_occurrences_exhausted} =
               Schedule.update_cron_schedule(
                 schedule.id,
                 %{
                   "schedule" => %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "anchor_at" => DateTime.to_iso8601(first_slot),
                     "occurrences" => %{"count" => 1}
                   }
                 },
                 now: DateTime.add(first_slot, 5, :second)
               )

      assert {:ok, unchanged} = Schedule.get_cron_schedule(schedule.id)
      assert unchanged.status == "active"
      assert unchanged.schedule["occurrences"] == nil
    end

    @tag ownership_timeout: 10_000
    test "a concurrent recurring fire and payload update serialize without a deadlock" do
      parent = self()
      first_slot = DateTime.add(@base_time, 1, :minute)
      unique = Ecto.UUID.generate()

      {agent_uid, schedule, event} =
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()

          assert {:ok, %{cron_schedule: schedule}} =
                   Schedule.create_cron_schedule(
                     cron_attrs(agent.uid,
                       name: "concurrent-#{unique}",
                       idempotency_key: "concurrent-#{unique}",
                       schedule: every_schedule(first_slot)
                     ),
                     now: @base_time
                   )

          [event] = Schedule.list_cron_runs(schedule.id, 10)
          {agent.uid, schedule, event}
        end)

      event_id = event.id

      on_exit(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          job_ids =
            ScheduledEvent
            |> where([scheduled_event], scheduled_event.agent_uid == ^agent_uid)
            |> select([scheduled_event], scheduled_event.oban_job_id)
            |> Repo.all()
            |> Enum.reject(&is_nil/1)

          if job_ids != [] do
            Oban.Job
            |> where([job], job.id in ^job_ids)
            |> Repo.delete_all()
          end

          Ankole.PrincipalsFixtures.delete_agent_fixture_rows(agent_uid)
        end)
      end)

      blocker =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            Repo.transact(fn repo ->
              event =
                ScheduledEvent
                |> where([scheduled_event], scheduled_event.id == ^event_id)
                |> lock("FOR UPDATE")
                |> repo.one!()

              send(parent, {:recurring_event_locked, self()})

              receive do
                :release_recurring_event -> {:ok, event.id}
              end
            end)
          end)
        end)

      assert_receive {:recurring_event_locked, blocker_pid}, 5_000

      fire =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            Schedule.fire_due_event(event_id, now: first_slot)
          end)
        end)

      Process.sleep(50)

      update =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            Schedule.update_cron_schedule(
              schedule.id,
              %{"payload" => %{"version" => 2, "task" => "digest"}},
              now: first_slot
            )
          end)
        end)

      Process.sleep(50)
      send(blocker_pid, :release_recurring_event)

      assert {:ok, ^event_id} = Task.await(blocker, 5_000)
      assert {:ok, %{status: :fired}} = Task.await(fire, 5_000)
      assert {:ok, %CronSchedule{}} = Task.await(update, 5_000)

      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        assert {:ok, current} = Schedule.get_cron_schedule(schedule.id)
        assert current.status == "active"

        live_events =
          ScheduledEvent
          |> where([scheduled_event], scheduled_event.cron_schedule_id == ^schedule.id)
          |> where([scheduled_event], scheduled_event.status in ["scheduled", "firing"])
          |> where(
            [scheduled_event],
            fragment(
              "COALESCE(?->>'trigger', 'scheduled') = 'scheduled'",
              scheduled_event.wake_payload
            )
          )
          |> Repo.all()

        assert [%ScheduledEvent{} = next] = live_events
        assert next.cron_fire_slot_at == current.next_fire_at
        assert next.wake_payload["payload"] == %{"version" => 2, "task" => "digest"}

        source_event_id = "cron:#{schedule.id}:#{DateTime.to_iso8601(first_slot)}"

        assert ActorEvent
               |> where([actor_event], actor_event.source_event_id == ^source_event_id)
               |> Repo.aggregate(:count) == 1
      end)
    end

    test "deleted cron names can be reused without poisoning list or name lookup" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()

      assert {:ok, %{cron_schedule: removed}} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid,
                   status: "paused",
                   name: "reusable-name",
                   idempotency_key: "reusable-name-old"
                 ),
                 now: @base_time
               )

      assert {:ok, %{status: "deleted"}} = Schedule.remove_cron_schedule(removed.id)

      assert {:ok, %{cron_schedule: current}} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid,
                   status: "paused",
                   name: "reusable-name",
                   idempotency_key: "reusable-name-current"
                 ),
                 now: @base_time
               )

      assert {:ok, fetched} =
               Schedule.get_cron_schedule_by_name(
                 agent.uid,
                 current.owner_session_id,
                 "reusable-name"
               )

      assert fetched.id == current.id

      assert Enum.map(
               Schedule.list_cron_schedules(agent.uid, current.owner_session_id),
               & &1.id
             ) == [
               current.id
             ]

      assert {:ok, %{status: "deleted"}} = Schedule.get_cron_schedule(removed.id)
    end

    test "cron updates reject empty and unknown changes" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()

      assert {:ok, %{cron_schedule: schedule}} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid,
                   status: "paused",
                   name: "validated-update",
                   idempotency_key: "validated-update"
                 ),
                 now: @base_time
               )

      assert {:error, :cron_schedule_update_required} =
               Schedule.update_cron_schedule(schedule.id, %{})

      assert {:error, {:unknown_cron_schedule_update_fields, ["failure_policy"]}} =
               Schedule.update_cron_schedule(schedule.id, %{"failure_policy" => %{}})
    end

    test "direct-Agent cron requires a self-contained task and a real owner conversation" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()

      assert {:error, :cron_task_required} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid, payload: %{}),
                 now: @base_time
               )

      assert {:error, :cron_task_required} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid, payload: %{"task" => "   "}),
                 now: @base_time
               )

      assert {:error, :cron_owner_session_reserved} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid, owner_session_id: "cron:#{Ecto.UUID.generate()}"),
                 now: @base_time
               )

      assert {:ok, %{cron_schedule: schedule}} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid, status: "paused", name: "task-guard"),
                 now: @base_time
               )

      assert {:error, :cron_task_required} =
               Schedule.update_cron_schedule(schedule.id, %{"payload" => %{"notes" => "no task"}})

      assert {:ok, updated} =
               Schedule.update_cron_schedule(schedule.id, %{"payload" => %{"task" => "new task"}})

      assert updated.payload == %{"task" => "new task"}

      assert {:ok, %{scheduled_event: manual_event}} =
               Schedule.run_cron_schedule(schedule.id,
                 now: @base_time,
                 tool_call_id: "legacy-task-guard"
               )

      CronSchedule
      |> where([cron_schedule], cron_schedule.id == ^schedule.id)
      |> Repo.update_all(set: [payload: %{}])

      assert {:error, :cron_task_required} =
               Schedule.resume_cron_schedule(schedule.id, now: @base_time)

      assert {:error, :cron_task_required} =
               Schedule.run_cron_schedule(schedule.id,
                 now: @base_time,
                 tool_call_id: "legacy-task-guard-retry"
               )

      assert {:ok, %{status: :cancelled, scheduled_event: cancelled}} =
               Schedule.fire_due_event(manual_event.id, now: @base_time)

      assert cancelled.last_fire_error == %{"reason" => ":cron_task_required"}

      assert {:ok, repaired} =
               Schedule.update_cron_schedule(schedule.id, %{
                 "payload" => %{"task" => "restored task"}
               })

      assert repaired.payload == %{"task" => "restored task"}

      assert {:ok, %{status: "active"}} =
               Schedule.resume_cron_schedule(schedule.id, now: @base_time)
    end

    test "payload and delivery changes end the execution conversation and terminal states end it too" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()

      assert {:ok, %{cron_schedule: schedule}} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid, status: "paused", name: "conversation-lifecycle"),
                 now: @base_time
               )

      execution_session_id = Schedule.cron_execution_session_id(schedule.id)

      ensure_execution_conversation = fn ->
        {:ok, conversation} =
          Ankole.AIGateway.Conversations.ensure_conversation(agent.uid, execution_session_id)

        conversation
      end

      active_execution_conversation = fn ->
        Ankole.SignalsGateway.AIGatewayLink.active_conversation(agent.uid, execution_session_id)
      end

      first = ensure_execution_conversation.()

      # A time-only change keeps the execution conversation and its history.
      assert {:ok, _updated} =
               Schedule.update_cron_schedule(schedule.id, %{
                 "schedule" => every_schedule(DateTime.add(@base_time, 2, :minute))
               })

      assert active_execution_conversation.().id == first.id

      # A task change makes the old history a wrong prefix, so it ends.
      assert {:ok, _updated} =
               Schedule.update_cron_schedule(schedule.id, %{
                 "payload" => %{"task" => "changed task"}
               })

      assert active_execution_conversation.() == nil

      second = ensure_execution_conversation.()

      assert {:ok, _updated} =
               Schedule.update_cron_schedule(schedule.id, %{
                 "delivery" => %{
                   "targets" => [
                     %{
                       "binding_name" => "bot",
                       "signal_channel_id" => "mock:chat:elsewhere",
                       "provider_thread_id" => "thread-elsewhere"
                     }
                   ]
                 }
               })

      assert active_execution_conversation.() == nil

      third = ensure_execution_conversation.()
      assert {:ok, %{status: "deleted"}} = Schedule.remove_cron_schedule(schedule.id)
      assert active_execution_conversation.() == nil
      assert Enum.uniq([first.id, second.id, third.id]) |> length() == 3
    end

    test "a timezone-only cron update changes the rule and its pending event" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()

      assert {:ok, %{cron_schedule: schedule}} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid,
                   name: "timezone-update",
                   idempotency_key: "timezone-update",
                   schedule: %{
                     "kind" => "cron",
                     "expression" => "0 9 * * *",
                     "timezone" => "Etc/UTC"
                   }
                 ),
                 now: @base_time
               )

      assert {:ok, updated} =
               Schedule.update_cron_schedule(
                 schedule.id,
                 %{"timezone" => "Asia/Shanghai"},
                 now: @base_time
               )

      assert updated.timezone == "Asia/Shanghai"
      assert updated.schedule["timezone"] == "Asia/Shanghai"

      assert [%ScheduledEvent{} = pending] =
               Schedule.list_cron_runs(schedule.id, 10)
               |> Enum.filter(&(&1.status == "scheduled"))

      assert pending.timezone == "Asia/Shanghai"
      assert pending.wake_payload["timezone"] == "Asia/Shanghai"
      assert pending.cron_fire_slot_at == updated.next_fire_at
    end

    test "release reconciliation repairs an active schedule with no live recurring event" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      first_slot = DateTime.add(@base_time, 1, :minute)
      repair_at = DateTime.add(@base_time, 10, :minute)

      assert {:ok, %{cron_schedule: schedule}} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid,
                   name: "stranded-repair",
                   idempotency_key: "stranded-repair",
                   schedule: every_schedule(first_slot)
                 ),
                 now: @base_time
               )

      [original] = Schedule.list_cron_runs(schedule.id, 10)

      original
      |> ScheduledEvent.changeset(%{
        status: "cancelled",
        cancelled_at: repair_at,
        last_fire_error: %{"reason" => "test_stranded"}
      })
      |> Repo.update!()

      assert {:ok, %{reconciled: reconciled}} =
               Schedule.reconcile_cron_schedules(now: repair_at)

      assert reconciled >= 1
      assert {:ok, repaired} = Schedule.get_cron_schedule(schedule.id)
      assert repaired.next_fire_at == DateTime.add(@base_time, 11, :minute)

      assert [replacement, cancelled] = Schedule.list_cron_runs(schedule.id, 10)
      assert replacement.status == "scheduled"
      assert replacement.cron_fire_slot_at == repaired.next_fire_at
      assert cancelled.id == original.id
      assert cancelled.status == "cancelled"
    end

    test "manual cron runs fire while paused without advancing recurrence" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      now = DateTime.add(@base_time, 1, :second)

      assert {:ok, %{status: :created, cron_schedule: schedule}} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid,
                   status: "paused",
                   name: "manual-paused",
                   idempotency_key: "manual-paused",
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "timezone" => "Etc/UTC",
                     "anchor_at" => DateTime.to_iso8601(DateTime.add(now, 1, :minute))
                   }
                 ),
                 now: now
               )

      assert {:ok, %{status: :scheduled, scheduled_event: manual_event}} =
               Schedule.run_cron_schedule(schedule.id,
                 now: now,
                 tool_call_id: "manual-paused-call"
               )

      assert manual_event.wake_payload["trigger"] == "manual"

      assert {:ok, %{status: :fired, actor_event: actor_event}} =
               Schedule.fire_due_event(manual_event.id, now: now)

      assert actor_event.type == "cron.fire"

      assert {:ok, unchanged} = Schedule.get_cron_schedule(schedule.id)
      assert unchanged.status == "paused"
      assert unchanged.next_fire_at == nil
      assert unchanged.last_fire_at == nil
    end

    test "pausing preserves a pending manual run while cancelling recurrence" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      first_slot = DateTime.add(@base_time, 5, :minute)

      assert {:ok, %{status: :created, cron_schedule: schedule}} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid,
                   name: "manual-before-pause",
                   idempotency_key: "manual-before-pause",
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "timezone" => "Etc/UTC",
                     "anchor_at" => DateTime.to_iso8601(first_slot)
                   }
                 ),
                 now: @base_time
               )

      assert {:ok, %{scheduled_event: manual_event}} =
               Schedule.run_cron_schedule(schedule.id,
                 now: @base_time,
                 tool_call_id: "manual-before-pause-call"
               )

      assert {:ok, paused} =
               Schedule.pause_cron_schedule(schedule.id,
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert paused.status == "paused"

      runs = Schedule.list_cron_runs(schedule.id, 10)
      assert Repo.get!(ScheduledEvent, manual_event.id).status == "scheduled"
      assert Enum.find(runs, &(&1.wake_payload["trigger"] == "scheduled")).status == "cancelled"

      assert {:ok, %{status: :fired}} =
               Schedule.fire_due_event(manual_event.id,
                 now: DateTime.add(@base_time, 1, :second)
               )
    end

    test "deleted cron schedules reject new manual runs and cancel pending ones" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()

      assert {:ok, %{status: :created, cron_schedule: schedule}} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid,
                   status: "paused",
                   name: "manual-before-delete",
                   idempotency_key: "manual-before-delete"
                 ),
                 now: @base_time
               )

      assert {:ok, %{scheduled_event: manual_event}} =
               Schedule.run_cron_schedule(schedule.id,
                 now: @base_time,
                 tool_call_id: "manual-before-delete-call"
               )

      assert {:ok, deleted} =
               Schedule.remove_cron_schedule(schedule.id,
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert deleted.status == "deleted"
      assert Repo.get!(ScheduledEvent, manual_event.id).status == "cancelled"
      assert {:error, :cron_schedule_deleted} = Schedule.run_cron_schedule(schedule.id)
    end

    test "cron created_by is trusted context, not caller attrs" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()

      assert {:ok, %{status: :created, cron_schedule: schedule}} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid,
                   name: "created-by-attrs-ignored",
                   idempotency_key: "created-by-attrs-ignored",
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 86_400_000,
                     "timezone" => "Etc/UTC",
                     "anchor_at" => DateTime.to_iso8601(DateTime.add(@base_time, 1, :day))
                   },
                   created_by: %{
                     "kind" => "spoofed",
                     "origin_ai_message_id" => Ecto.UUID.generate()
                   }
                 ),
                 now: @base_time
               )

      assert schedule.created_by == %{"kind" => "operator_api"}
      assert [event] = Schedule.list_cron_runs(schedule.id, 10)
      assert event.origin_ai_message_id == nil
    end

    test "scheduled event correlation ids must reference durable rows" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      due_at = DateTime.add(@base_time, 5, :minute)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Schedule.create_check_back_later(
                 checkback_attrs(agent.uid,
                   idempotency_key: "missing-source-actor-event",
                   source_actor_event_id: Ecto.UUID.generate(),
                   schedule: %{"at" => DateTime.to_iso8601(due_at), "timezone" => "Etc/UTC"}
                 ),
                 now: @base_time
               )

      assert %{source_actor_event_id: [_ | _]} = errors_on(changeset)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Schedule.create_check_back_later(
                 checkback_attrs(agent.uid,
                   idempotency_key: "missing-origin-ai-message",
                   origin_ai_message_id: Ecto.UUID.generate(),
                   schedule: %{"at" => DateTime.to_iso8601(due_at), "timezone" => "Etc/UTC"}
                 ),
                 now: @base_time
               )

      assert %{origin_ai_message_id: [_ | _]} = errors_on(changeset)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Repo.insert(
                 ScheduledEvent.changeset(%ScheduledEvent{}, %{
                   kind: "check_back_later",
                   status: "scheduled",
                   agent_uid: agent.uid,
                   session_id: "mock:chat:schedule",
                   binding_name: "bot",
                   due_at: due_at,
                   timezone: "Etc/UTC",
                   requested_at: @base_time,
                   idempotency_key: "missing-fired-actor-event",
                   actor_event_id: Ecto.UUID.generate(),
                   source_provenance: %{},
                   wake_payload: %{},
                   last_fire_error: %{}
                 })
               )

      assert %{actor_event_id: [_ | _]} = errors_on(changeset)
    end

    test "cancelled checkback does not fire after source entry tombstone" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{actor_event: source_event}} =
               emit_entry(agent.uid, "bot", group_entry(%{explicit: true}), now: @base_time)

      assert {:ok, _consumed} =
               complete_actor_event(
                 agent.uid,
                 "bot",
                 source_event.source_event_id,
                 actor_commit_opts(completed_at: DateTime.add(@base_time, 1, :second))
               )

      due_at = DateTime.add(@base_time, 5, :minute)

      assert {:ok, %{scheduled_event: event}} =
               Schedule.create_check_back_later(
                 checkback_attrs(agent.uid,
                   session_id: source_event.session_id,
                   reply_route: %{
                     "signal_channel_id" => source_event.signal_channel_id,
                     "provider_thread_id" => source_event.provider_thread_id,
                     "source_entry_id" => source_event.source_entry_id
                   },
                   source_actor_event_id: source_event.id,
                   schedule: %{"at" => DateTime.to_iso8601(due_at), "timezone" => "Etc/UTC"}
                 ),
                 now: @base_time
               )

      assert {:ok, %{lifecycle_events: [lifecycle_event]}} =
               Ingress.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{source_event_id: "delete-source"}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, %{status: :entry_lifecycle_ignored, cancelled_checkbacks: 1}} =
               process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

      assert %ActorEvent{completed_at: %DateTime{}} = Repo.get(ActorEvent, lifecycle_event.id)
      assert Repo.get!(ScheduledEvent, event.id).status == "cancelled"
      assert {:ok, %{status: :noop}} = Schedule.fire_due_event(event.id, now: due_at)
    end
  end

  describe "runtime schedule turns" do
    test "schedule RPC creates checkbacks only from the assigned route and current reply route" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      route = unique_route()
      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_event: source_event}} =
               emit_entry(agent.uid, "bot", group_entry(%{explicit: true}), now: @base_time)

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}
      turn_ref = turn_start_payload!(envelope).turn

      assert {:ok, conversation} =
               Conversations.ensure_conversation(agent.uid, source_event.session_id)

      assert {:ok, generating_message} =
               StatefulResponses.start_response_run(%{
                 subject_uid: agent.uid,
                 conversation_id: conversation.id,
                 metadata: %{
                   "request_metadata" => %{"actor_event_id" => turn_ref.actor_event_id}
                 }
               })

      reply_route = %{
        "binding_name" => source_event.binding_name,
        "signal_channel_id" => source_event.signal_channel_id,
        "provider_thread_id" => source_event.provider_thread_id,
        "source_entry_id" => source_event.source_entry_id
      }

      request = %FabricProto.ScheduleCheckBackLaterCreateRequest{
        tool_call_id: "checkback-call-1",
        idempotency_key: "schedule-rpc-checkback-1",
        schedule_json:
          Torque.encode!(%{
            "after" => %{"value" => 5, "unit" => "minute"},
            "timezone" => "Etc/UTC"
          }),
        reason: "Deployment is still running.",
        check: "Ask whether the deployment finished.",
        quiet_success: true,
        reply_route_json: Torque.encode!(reply_route)
      }

      assert {:ok,
              %{
                "status" => "scheduled",
                "timezone" => "Etc/UTC",
                "quiet_success" => true
              } = created} = schedule_rpc("check_back_later.create", request, turn_ref, route)

      refute Map.has_key?(created, "checkback_id")
      refute Map.has_key?(created, "scheduled_event_id")

      scheduled_event =
        Repo.get_by!(ScheduledEvent,
          agent_uid: agent.uid,
          session_id: source_event.session_id,
          idempotency_key: "schedule-rpc-checkback-1"
        )

      scheduled_event_id = scheduled_event.id
      assert scheduled_event.source_actor_event_id == source_event.id
      assert scheduled_event.origin_ai_message_id == generating_message.id
      assert scheduled_event.wake_payload["quiet_success"] == true

      assert {:ok,
              %{
                "status" => "already_scheduled",
                "quiet_success" => true
              } = duplicate} =
               schedule_rpc(
                 "check_back_later.create",
                 %{request | quiet_success: false},
                 turn_ref,
                 route
               )

      refute Map.has_key?(duplicate, "checkback_id")
      refute Map.has_key?(duplicate, "scheduled_event_id")

      assert {:ok,
              %{
                "status" => "ok",
                "checkbacks" => [
                  %{"checkback_id" => ^scheduled_event_id, "status" => "scheduled"}
                ]
              }} =
               schedule_rpc(
                 "check_back_later.list",
                 %FabricProto.ScheduleCheckBackLaterListRequest{limit: 5},
                 turn_ref,
                 route
               )

      assert {:ok,
              %{
                "status" => "ok",
                "checkback" => %{
                  "checkback_id" => ^scheduled_event_id,
                  "check" => "Ask whether the deployment finished."
                }
              }} =
               schedule_rpc(
                 "check_back_later.get",
                 %FabricProto.ScheduleCheckBackLaterTargetRequest{
                   scheduled_event_id: scheduled_event_id
                 },
                 turn_ref,
                 route
               )

      assert {:ok,
              %{
                "status" => "updated",
                "checkback" => %{
                  "checkback_id" => replacement_event_id,
                  "status" => "scheduled",
                  "check" => "Let evidence density determine the PDF length.",
                  "context_summary" => "The user removed the 6–12 page constraint."
                }
              }} =
               schedule_rpc(
                 "check_back_later.update",
                 %FabricProto.ScheduleCheckBackLaterUpdateRequest{
                   scheduled_event_id: scheduled_event_id,
                   tool_call_id: "checkback-call-update-1",
                   idempotency_key: "schedule-rpc-checkback-update-1",
                   updates_json:
                     Torque.encode!(%{
                       "check" => "Let evidence density determine the PDF length.",
                       "context_summary" => "The user removed the 6–12 page constraint."
                     }),
                   reply_route_json: Torque.encode!(reply_route)
                 },
                 turn_ref,
                 route
               )

      assert replacement_event_id != scheduled_event_id
      assert Repo.get!(ScheduledEvent, scheduled_event_id).status == "cancelled"
      assert Repo.get!(ScheduledEvent, replacement_event_id).status == "scheduled"

      assert {:ok,
              %{
                "status" => "ok",
                "checkback" => %{
                  "checkback_id" => ^replacement_event_id,
                  "status" => "scheduled"
                }
              }} =
               schedule_rpc(
                 "check_back_later.get",
                 %FabricProto.ScheduleCheckBackLaterTargetRequest{
                   scheduled_event_id: scheduled_event_id
                 },
                 turn_ref,
                 route
               )

      assert {:ok,
              %{
                "status" => "ok",
                "checkbacks" => [
                  %{"checkback_id" => ^replacement_event_id, "status" => "scheduled"}
                ]
              }} =
               schedule_rpc(
                 "check_back_later.list",
                 %FabricProto.ScheduleCheckBackLaterListRequest{},
                 turn_ref,
                 route
               )

      assert {:error, %{"code" => "unknown_checkback_update_fields"}} =
               schedule_rpc(
                 "check_back_later.update",
                 %FabricProto.ScheduleCheckBackLaterUpdateRequest{
                   scheduled_event_id: replacement_event_id,
                   tool_call_id: "checkback-call-update-unknown",
                   idempotency_key: "schedule-rpc-checkback-update-unknown",
                   updates_json: Torque.encode!(%{"pages" => "unbounded"}),
                   reply_route_json: Torque.encode!(reply_route)
                 },
                 turn_ref,
                 route
               )

      assert {:ok,
              %{
                "status" => "cancelled",
                "checkback" => %{
                  "checkback_id" => ^replacement_event_id,
                  "status" => "cancelled"
                }
              }} =
               schedule_rpc(
                 "check_back_later.cancel",
                 %FabricProto.ScheduleCheckBackLaterTargetRequest{
                   scheduled_event_id: scheduled_event_id
                 },
                 turn_ref,
                 route
               )

      assert {:ok, %{scheduled_event: other_session_event}} =
               Schedule.create_check_back_later(
                 checkback_attrs(agent.uid,
                   session_id: "mock:chat:other-session",
                   idempotency_key: "schedule-rpc-other-session"
                 ),
                 now: @base_time
               )

      assert {:ok, %{"status" => "ok", "checkbacks" => []}} =
               schedule_rpc(
                 "check_back_later.list",
                 %FabricProto.ScheduleCheckBackLaterListRequest{},
                 turn_ref,
                 route
               )

      assert {:error, %{"code" => "checkback_not_in_turn"}} =
               schedule_rpc(
                 "check_back_later.get",
                 %FabricProto.ScheduleCheckBackLaterTargetRequest{
                   scheduled_event_id: other_session_event.id
                 },
                 turn_ref,
                 route
               )

      bad_reply_route = %{reply_route | "source_entry_id" => "not-current-entry"}

      assert {:error, %{"code" => "reply_route_not_in_turn"}} =
               schedule_rpc(
                 "check_back_later.create",
                 %{
                   request
                   | idempotency_key: "schedule-rpc-checkback-bad-route",
                     reply_route_json: Torque.encode!(bad_reply_route)
                 },
                 turn_ref,
                 route
               )

      cron_request = %FabricProto.ScheduleCronAddRequest{
        binding_name: source_event.binding_name,
        name: "dashboard-route-cron",
        schedule_json:
          Torque.encode!(%{
            "kind" => "cron",
            "expression" => "0 7 * * *",
            "timezone" => "Asia/Shanghai"
          }),
        payload_json: Torque.encode!(%{"task" => "dashboard-check"}),
        delivery_json:
          Torque.encode!(%{
            "targets" => [
              %{
                "binding_name" => source_event.binding_name,
                "signal_channel_id" => source_event.signal_channel_id,
                "provider_thread_id" => source_event.provider_thread_id
              }
            ]
          }),
        idempotency_key: "schedule-rpc-cron-1"
      }

      assert {:ok,
              %{
                "status" => "created",
                "schedule" => %{"name" => "dashboard-route-cron"} = model_schedule
              }} =
               schedule_rpc("cron.add", cron_request, turn_ref, route)

      refute Map.has_key?(model_schedule, "id")

      bad_cron_delivery = %{
        "targets" => [
          %{
            "binding_name" => source_event.binding_name,
            "signal_channel_id" => "not-current-channel",
            "provider_thread_id" => source_event.provider_thread_id
          }
        ]
      }

      assert {:error, %{"code" => "reply_route_not_in_turn"}} =
               schedule_rpc(
                 "cron.add",
                 %{
                   cron_request
                   | idempotency_key: "schedule-rpc-cron-bad-route",
                     delivery_json: Torque.encode!(bad_cron_delivery)
                 },
                 turn_ref,
                 route
               )

      assert {:error, %{"code" => "reply_route_not_in_turn"}} =
               schedule_rpc(
                 "cron.update",
                 %FabricProto.ScheduleCronUpdateRequest{
                   name: "dashboard-route-cron",
                   updates_json: Torque.encode!(%{"delivery" => bad_cron_delivery})
                 },
                 turn_ref,
                 route
               )

      assert {:error, %{"code" => "reply_route_not_in_turn"}} =
               schedule_rpc(
                 "cron.update",
                 %FabricProto.ScheduleCronUpdateRequest{
                   name: "dashboard-route-cron",
                   updates_json:
                     Torque.encode!(%{
                       "delivery" => %{
                         "targets" => [
                           %{
                             "binding_name" => source_event.binding_name,
                             "signal_channel_id" => source_event.signal_channel_id
                           },
                           %{
                             "binding_name" => "secondary-binding",
                             "signal_channel_id" => "secondary-channel"
                           }
                         ]
                       }
                     })
                 },
                 turn_ref,
                 route
               )

      assert {:ok, stored_schedule} =
               Schedule.get_cron_schedule_by_name(
                 turn_ref.actor.agent_uid,
                 turn_ref.actor.session_id,
                 "dashboard-route-cron"
               )

      targets = [
        %{
          "binding_name" => source_event.binding_name,
          "signal_channel_id" => source_event.signal_channel_id,
          "provider_thread_id" => source_event.provider_thread_id
        },
        %{
          "binding_name" => "secondary-binding",
          "signal_channel_id" => "secondary-channel"
        }
      ]

      assert {:ok, _updated} =
               Schedule.update_cron_schedule(stored_schedule.id, %{
                 "delivery" => %{"targets" => targets}
               })

      assert {:ok, %{"status" => "updated"}} =
               schedule_rpc(
                 "cron.update",
                 %FabricProto.ScheduleCronUpdateRequest{
                   name: "dashboard-route-cron",
                   updates_json: Torque.encode!(%{"delivery" => %{"quiet_success" => true}})
                 },
                 turn_ref,
                 route
               )

      assert {:ok, option_updated} = Schedule.get_cron_schedule(stored_schedule.id)
      assert option_updated.delivery == %{"targets" => targets, "quiet_success" => true}

      assert {:error, %{"code" => "worker_not_assigned_to_turn"}} =
               schedule_rpc(
                 "check_back_later.create",
                 %{request | idempotency_key: "schedule-rpc-checkback-wrong-worker"},
                 turn_ref,
                 "wrong-worker-route"
               )
    end

    test "mock IM dashboard cron story fires through Oban and posts service lines" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "mock-provider", :ignore, "mock-provider")

      consumer =
        MockInbound.chat_consumer(
          mock_adapter_context(agent.uid, "mock-provider"),
          %{},
          now: @base_time
        )

      assert {:ok, [receive_result]} =
               MockInbound.handle_message_receive(
                 "message.receive",
                 %{
                   source_event_id: "mock-dashboard-cron-request",
                   signal_channel_id: "mock:chat:dashboard",
                   source_entry_id: "mock-dashboard-request-message",
                   provider_thread_id: "mock-dashboard-thread",
                   text:
                     "Every morning at 7 check https://status.internal and post one line per service: green, or what's off and since when.",
                   explicit: true,
                   now: @base_time,
                   provider_time: @base_time
                 },
                 [consumer]
               )

      %{actor_event: source_event} = maybe_finalize_test_inbound_batch(receive_result)

      route = unique_route()
      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}
      turn_start = turn_start_payload!(envelope)
      turn_ref = turn_start.turn

      assert turn_ref.actor.session_id == source_event.session_id

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(turn_accepted_payload(turn_ref))

      assert {:ok,
              %{
                "status" => "created",
                "schedule" => %{"name" => "dashboard-morning-check"} = model_schedule
              }} =
               schedule_rpc(
                 "cron.add",
                 %FabricProto.ScheduleCronAddRequest{
                   binding_name: "mock-provider",
                   name: "dashboard-morning-check",
                   schedule_json:
                     Torque.encode!(%{
                       "kind" => "cron",
                       "expression" => "0 7 * * *",
                       "timezone" => "Asia/Shanghai"
                     }),
                   payload_json:
                     Torque.encode!(%{
                       "task" => "dashboard_status_check",
                       "dashboard_url" => "https://status.internal",
                       "services" => ["api", "billing", "search"],
                       "report_format" =>
                         "one line per service: green, or what's off and since when"
                     }),
                   delivery_json:
                     Torque.encode!(%{
                       "targets" => [
                         %{
                           "binding_name" => source_event.binding_name,
                           "signal_channel_id" => source_event.signal_channel_id,
                           "provider_thread_id" => source_event.provider_thread_id
                         }
                       ]
                     }),
                   idempotency_key: "dashboard-cron-story"
                 },
                 turn_ref,
                 route
               )

      refute Map.has_key?(model_schedule, "id")

      assert {:ok, cron_schedule} =
               Schedule.get_cron_schedule_by_name(
                 turn_ref.actor.agent_uid,
                 turn_ref.actor.session_id,
                 "dashboard-morning-check"
               )

      scheduled_ack =
        complete_turn_via_aigateway!(
          turn_ref,
          "Scheduled the dashboard check for 07:00 Asia/Shanghai."
        )

      dispatch_final_reply_outbox!(scheduled_ack.id)
      assert wait_for_final_mirror(scheduled_ack.id).signal_channel_id == "mock:chat:dashboard"

      [scheduled_event] = Schedule.list_cron_runs(cron_schedule.id, 10)
      due_now = DateTime.add(DateTime.utc_now(:microsecond), -1, :second)

      scheduled_event
      |> ScheduledEvent.changeset(%{due_at: due_now, cron_fire_slot_at: due_now})
      |> Repo.update!()

      cron_schedule
      |> CronSchedule.changeset(%{next_fire_at: due_now})
      |> Repo.update!()

      assert :ok =
               perform_job(Ankole.SignalsGateway.ActorRuntime.Jobs.FireScheduledEvent, %{
                 "scheduled_event_id" => scheduled_event.id
               })

      fired_event = Repo.get!(ScheduledEvent, scheduled_event.id)
      cron_input = Repo.get!(ActorEvent, fired_event.actor_event_id)

      assert cron_input.type == "cron.fire"
      assert cron_input.signal_channel_id == source_event.signal_channel_id
      assert cron_input.source_entry_id == nil

      assert get_in(cron_input.payload, [
               "data",
               "wake_payload",
               "payload",
               "dashboard_url"
             ]) == "https://status.internal"

      cron_envelope =
        receive do
          {:actor_lane, envelope} ->
            envelope
        after
          250 ->
            assert {:ok, %{send_outcome: "sent_or_queued"}} =
                     process_ready_events_once(
                       now: DateTime.add(DateTime.utc_now(:microsecond), 1, :second),
                       lease_seconds: @long_lease_seconds
                     )

            assert_receive {:actor_lane, envelope}
            envelope
        end

      cron_turn_start = turn_start_payload!(cron_envelope)
      cron_turn_ref = cron_turn_start.turn
      cron_context = decoded_request_context(cron_turn_start)

      refute Map.has_key?(cron_context, "turn_mode")
      assert is_map(cron_context["schedule_origin"])
      assert cron_context["silent_success_allowed"] == false

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(turn_accepted_payload(cron_turn_ref))

      dashboard_report = """
      api: green
      billing: green
      search: degraded since 2026-07-05 06:42 Asia/Shanghai
      """

      committed = complete_turn_via_aigateway!(cron_turn_ref, dashboard_report)
      dispatch_final_reply_outbox!(committed.id)
      mirror = wait_for_final_mirror(committed.id)

      assert mirror.signal_channel_id == "mock:chat:dashboard"
      assert mirror.text == String.trim_trailing(dashboard_report)
      assert mirror.ai_message_id == committed.id
      assert mirror.metadata["actor_event_id"] == cron_input.id
    end

    test "checkback wakeup can finish silently only with explicit quiet success" do
      %{principal: agent} = agent_fixture()
      route = unique_route()
      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      due_at = DateTime.add(@base_time, 1, :minute)

      assert {:ok, %{scheduled_event: event}} =
               Schedule.create_check_back_later(
                 checkback_attrs(agent.uid,
                   quiet_success: true,
                   schedule: %{"at" => DateTime.to_iso8601(due_at), "timezone" => "Etc/UTC"}
                 ),
                 now: @base_time
               )

      assert {:ok, %{actor_event: input}} = Schedule.fire_due_event(event.id, now: due_at)

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               process_ready_events_once(
                 now: DateTime.add(due_at, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}
      turn_start = turn_start_payload!(envelope)
      turn_ref = turn_start.turn
      input_ids = Enum.map(List.wrap(turn_start.actor_event), & &1.actor_event_id)

      assert input_ids == [input.id]

      assert [
               %FabricProto.ActorEventEnvelope{
                 type: "check_back_later.wakeup",
                 signal_channel_id: "mock:chat:schedule"
               }
             ] =
               List.wrap(turn_start.actor_event)

      context = decoded_request_context(turn_start)
      refute Map.has_key?(context, "turn_mode")
      assert is_map(context["schedule_origin"])
      assert context["silent_success_allowed"] == true

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(turn_accepted_payload(turn_ref))

      assert {:ok, %{status: :noop_completed}} =
               complete_turn_noop(turn_ref, "schedule_silent_success")

      # Actor events are durable — completion records the terminal timestamp.
      assert Repo.get(ActorEvent, input.id)

      assert Repo.aggregate(
               from(event in ActorEvent, where: not is_nil(event.completed_at)),
               :count
             ) == 1

      assert Repo.aggregate(OutboxEntry, :count) == 0
      assert Repo.aggregate(ActorEventDelivery, :count) == 0
    end

    test "cron fire starts a scheduled_task turn and posts to configured delivery" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore, "mock-provider")
      seed_mock_channel(agent.uid, "bot")

      route = unique_route()
      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      first_slot = DateTime.add(@base_time, 1, :minute)

      assert {:ok, %{cron_schedule: schedule}} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid,
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "timezone" => "Etc/UTC",
                     "anchor_at" => DateTime.to_iso8601(first_slot)
                   }
                 ),
                 now: @base_time
               )

      [event] = Schedule.list_cron_runs(schedule.id, 10)
      assert {:ok, %{actor_event: input}} = Schedule.fire_due_event(event.id, now: first_slot)

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               process_ready_events_once(
                 now: DateTime.add(first_slot, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}
      turn_start = turn_start_payload!(envelope)
      turn_ref = turn_start.turn
      context = decoded_request_context(turn_start)

      assert [%FabricProto.ActorEventEnvelope{type: "cron.fire"}] =
               List.wrap(turn_start.actor_event)

      refute Map.has_key?(context, "turn_mode")
      assert is_map(context["schedule_origin"])
      assert context["silent_success_allowed"] == false

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(turn_accepted_payload(turn_ref))

      assert %Message{} =
               committed = complete_turn_via_aigateway!(turn_ref, "Daily digest is ready.")

      dispatch_final_reply_outbox!(committed.id)
      mirror = wait_for_final_mirror(committed.id)
      assert mirror.signal_channel_id == "mock:chat:schedule"
      assert mirror.text == "Daily digest is ready."
      assert mirror.ai_message_id == committed.id
      assert mirror.metadata["actor_event_id"] == input.id
    end

    test "a running conversation turn does not delay a cron fire, and one schedule stays serial" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore, "mock-provider")
      seed_mock_channel(agent.uid, "bot")

      route = unique_route()
      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      # Hold the owner conversation open with an addressed message turn.
      assert {:ok, %{actor_event: channel_input}} =
               emit_entry(agent.uid, "bot", group_entry(%{explicit: true}), now: @base_time)

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, channel_envelope}
      channel_turn_ref = turn_start_payload!(channel_envelope).turn

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(turn_accepted_payload(channel_turn_ref))

      first_slot = DateTime.add(@base_time, 1, :minute)

      assert {:ok, %{cron_schedule: schedule}} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid,
                   owner_session_id: channel_input.session_id,
                   delivery: %{
                     "targets" => [
                       %{
                         "binding_name" => channel_input.binding_name,
                         "signal_channel_id" => channel_input.signal_channel_id,
                         "provider_thread_id" => channel_input.provider_thread_id
                       }
                     ]
                   },
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "timezone" => "Etc/UTC",
                     "anchor_at" => DateTime.to_iso8601(first_slot)
                   }
                 ),
                 now: @base_time
               )

      [event] = Schedule.list_cron_runs(schedule.id, 10)

      assert {:ok, %{actor_event: cron_input}} =
               Schedule.fire_due_event(event.id, now: first_slot)

      execution_actor = %{
        agent_uid: agent.uid,
        session_id: Schedule.cron_execution_session_id(schedule.id)
      }

      assert cron_input.session_id == execution_actor.session_id

      # The fire admits while the owner conversation turn still runs.
      assert {:ok, %{send_outcome: "sent_or_queued", conversation: cron_conversation}} =
               ActorRuntime.process_ready_event_for_actor(execution_actor,
                 now: DateTime.add(first_slot, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert cron_conversation.conversation_key == execution_actor.session_id

      assert_receive {:actor_lane, cron_envelope}
      cron_turn_start = turn_start_payload!(cron_envelope)
      cron_turn_ref = cron_turn_start.turn
      cron_context = decoded_request_context(cron_turn_start)

      assert [%FabricProto.ActorEventEnvelope{type: "cron.fire"}] =
               List.wrap(cron_turn_start.actor_event)

      refute Map.has_key?(cron_context, "turn_mode")
      assert is_map(cron_context["schedule_origin"])
      assert cron_context["silent_success_allowed"] == false

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(turn_accepted_payload(cron_turn_ref))

      # A second fire of the same schedule waits for the first turn.
      manual_fire_at = DateTime.add(first_slot, 2, :second)

      assert {:ok, %{scheduled_event: manual_event}} =
               Schedule.run_cron_schedule(schedule.id,
                 idempotency_key: "manual-while-running",
                 now: manual_fire_at
               )

      assert {:ok, %{actor_event: manual_input}} =
               Schedule.fire_due_event(manual_event.id, now: manual_fire_at)

      assert manual_input.session_id == execution_actor.session_id

      assert {:ok, %{status: :idle}} =
               ActorRuntime.process_ready_event_for_actor(execution_actor,
                 now: DateTime.add(first_slot, 3, :second)
               )

      committed = complete_turn_via_aigateway!(cron_turn_ref, "first fire done")
      dispatch_final_reply_outbox!(committed.id)
      assert wait_for_final_mirror(committed.id).ai_message_id == committed.id

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               ActorRuntime.process_ready_event_for_actor(execution_actor,
                 now: DateTime.add(first_slot, 4, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, manual_envelope}
      assert turn_start_payload!(manual_envelope).actor_event.actor_event_id == manual_input.id
    end

    test "cron-origin turns cannot broadly mutate cron schedules" do
      %{principal: agent} = agent_fixture()
      route = unique_route()
      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      first_slot = DateTime.add(@base_time, 1, :minute)

      assert {:ok, %{cron_schedule: schedule}} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid,
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "timezone" => "Etc/UTC",
                     "anchor_at" => DateTime.to_iso8601(first_slot)
                   }
                 ),
                 now: @base_time
               )

      [event] = Schedule.list_cron_runs(schedule.id, 10)
      assert {:ok, %{actor_event: _input}} = Schedule.fire_due_event(event.id, now: first_slot)

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               process_ready_events_once(
                 now: DateTime.add(first_slot, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}
      turn_ref = turn_start_payload!(envelope).turn

      assert {:ok, %{"runs" => [projected_run | _rest]}} =
               schedule_rpc(
                 "cron.runs",
                 %FabricProto.ScheduleCronRunsRequest{},
                 turn_ref,
                 route
               )

      assert Map.has_key?(projected_run, "trigger")
      refute Map.has_key?(projected_run, "cron_schedule_id")
      refute Map.has_key?(projected_run, "wake_payload")
      refute Map.has_key?(projected_run, "source_provenance")
      refute Map.has_key?(projected_run, "oban_job_id")
      refute Map.has_key?(projected_run, "fire_attempts")
      refute Map.has_key?(projected_run, "last_fire_error")

      # A cron-origin turn resolves exactly its own schedule through provenance.
      assert {:ok, %{"schedules" => [own_schedule]}} =
               schedule_rpc("cron.list", %FabricProto.ScheduleCronListRequest{}, turn_ref, route)

      assert own_schedule["name"] == "daily-digest"

      assert {:ok, %{"schedule" => %{"name" => "daily-digest"}}} =
               schedule_rpc(
                 "cron.get",
                 %FabricProto.ScheduleCronTargetRequest{name: "daily-digest"},
                 turn_ref,
                 route
               )

      assert {:error, %{"code" => "cron_origin_broad_cron_mutation_denied"}} =
               schedule_rpc(
                 "cron.pause",
                 %FabricProto.ScheduleCronTargetRequest{},
                 turn_ref,
                 route
               )

      assert (Schedule.get_cron_schedule(schedule.id) |> elem(1)).status == "active"
    end

    test "cron quiet success consumes the fire without provider outbox" do
      %{principal: agent} = agent_fixture()
      route = unique_route()
      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      first_slot = DateTime.add(@base_time, 1, :minute)

      assert {:ok, %{cron_schedule: schedule}} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid,
                   delivery: %{
                     "targets" => [
                       %{
                         "binding_name" => "bot",
                         "signal_channel_id" => "mock:chat:schedule",
                         "provider_thread_id" => "thread-schedule"
                       }
                     ],
                     "quiet_success" => true
                   },
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "timezone" => "Etc/UTC",
                     "anchor_at" => DateTime.to_iso8601(first_slot)
                   }
                 ),
                 now: @base_time
               )

      [event] = Schedule.list_cron_runs(schedule.id, 10)
      assert {:ok, %{actor_event: input}} = Schedule.fire_due_event(event.id, now: first_slot)

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               process_ready_events_once(
                 now: DateTime.add(first_slot, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}
      turn_start = turn_start_payload!(envelope)
      turn_ref = turn_start.turn

      assert decoded_request_context(turn_start)["silent_success_allowed"] == true

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(turn_accepted_payload(turn_ref))

      assert {:ok, %{status: :noop_completed}} =
               complete_turn_noop(turn_ref, "schedule_silent_success")

      # Actor events are durable — completion records the terminal timestamp.
      assert Repo.get(ActorEvent, input.id)
      assert Repo.aggregate(OutboxEntry, :count) == 0
    end

    test "session reset preserves an overdue cron fire until it materializes" do
      %{principal: agent} = agent_fixture()
      first_slot = DateTime.add(@base_time, 1, :minute)
      reset_at = DateTime.add(@base_time, 2, :minute)

      assert {:ok, %{cron_schedule: schedule}} =
               Schedule.create_cron_schedule(
                 cron_attrs(agent.uid,
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "timezone" => "Etc/UTC",
                     "anchor_at" => DateTime.to_iso8601(first_slot)
                   }
                 ),
                 now: @base_time
               )

      execution_session_id = Schedule.cron_execution_session_id(schedule.id)

      assert {:ok, _conversation} =
               Ankole.AIGateway.Conversations.ensure_conversation(agent.uid, execution_session_id)

      [old_event] = Schedule.list_cron_runs(schedule.id, 10)
      assert old_event.due_at == first_slot

      assert {:ok, reset_event} =
               append_runtime_actor_event(agent.uid, execution_session_id, "session.reset_due",
                 now: reset_at,
                 boundary_at: reset_at
               )

      assert {:ok,
              %{
                status: :session_reset,
                reset_event: ^reset_event
              }} =
               process_ready_events_once(now: reset_at)

      preserved_event = Repo.get!(ScheduledEvent, old_event.id)
      assert preserved_event.status == "scheduled"
      assert preserved_event.cron_fire_slot_at == first_slot

      before_fire = Schedule.get_cron_schedule(schedule.id) |> elem(1)
      assert before_fire.last_fire_at == nil
      assert before_fire.next_fire_at == first_slot

      assert {:ok, %{status: :fired, actor_event: cron_input}} =
               Schedule.fire_due_event(old_event.id, now: reset_at)

      assert cron_input.type == "cron.fire"

      assert cron_input.source_event_id ==
               "cron:#{schedule.id}:#{DateTime.to_iso8601(first_slot)}"

      assert get_in(cron_input.payload, ["data", "cron_fire_slot_at"]) ==
               DateTime.to_iso8601(first_slot)

      assert {:ok, %{status: :noop}} = Schedule.fire_due_event(old_event.id, now: reset_at)

      reloaded = Schedule.get_cron_schedule(schedule.id) |> elem(1)
      assert reloaded.last_fire_at == first_slot
      assert reloaded.next_fire_at == DateTime.add(@base_time, 3, :minute)

      runs = Schedule.list_cron_runs(schedule.id, 10)

      assert Enum.map(runs, &{&1.status, &1.due_at}) == [
               {"scheduled", DateTime.add(@base_time, 3, :minute)},
               {"fired", first_slot}
             ]
    end
  end

  defp agent_fixture(attrs \\ %{}) do
    %{principal: agent} = fixture = Ankole.PrincipalsFixtures.agent_fixture(attrs)
    provider_id = "schedule-test-" <> Ecto.UUID.generate()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openrouter",
               base_url: "https://openrouter.ai/api/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-test"}]
               }
             })

    :ok = Ankole.SignalsGateway.ActorRuntimeCase.cache_actor_runtime_models(provider_id)

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: provider_id,
               model: "google/gemini-3.5-flash"
             })

    fixture
  end

  defp use_mock_signal_provider_plugin(_context) do
    original_state = :sys.get_state(Ankole.Plugins.Registry)
    {:ok, spec} = Spec.from_module(MockSignalProviderPlugin)

    :sys.replace_state(Ankole.Plugins.Registry, fn _state ->
      %{
        discovered: %{spec.id => spec},
        active: %{spec.id => spec},
        enabled_ids: MapSet.new([spec.id])
      }
    end)

    on_exit(fn ->
      :sys.replace_state(Ankole.Plugins.Registry, fn _state -> original_state end)
    end)

    :ok
  end

  defp seed_mock_channel(agent_uid, binding_name) do
    consumer =
      MockInbound.chat_consumer(
        mock_adapter_context(agent_uid, binding_name),
        %{},
        now: @base_time
      )

    assert {:ok, [_result]} =
             MockInbound.handle_message_receive(
               "message.receive",
               %{
                 source_event_id: "mock-channel-seed-#{binding_name}",
                 signal_channel_id: "mock:chat:schedule",
                 source_entry_id: "mock-channel-seed-message-#{binding_name}",
                 provider_thread_id: "thread-schedule",
                 text: "channel seed",
                 explicit: false,
                 now: @base_time,
                 provider_time: @base_time
               },
               [consumer]
             )
  end

  defp complete_turn_via_aigateway!(turn_ref, text) do
    proto_ref = turn_proto_ref(turn_ref)
    agent_uid = proto_ref.actor.agent_uid
    session_id = proto_ref.actor.session_id
    actor_event_id = proto_ref.actor_event_id

    {:ok, conversation} = Conversations.ensure_conversation(agent_uid, session_id)

    {:ok, run} =
      StatefulResponses.start_response_run(%{
        subject_uid: agent_uid,
        conversation_id: conversation.id,
        metadata: %{"request_metadata" => %{"actor_event_id" => actor_event_id}}
      })

    {:ok, committed} =
      StatefulResponses.commit_complete(run, [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => text}]
        }
      ])

    assert {:ok, %{status: :turn_completed}} =
             commit_turn_completion(turn_ref, "resp_#{committed.id}", "loop_finished")

    committed
  end

  defp wait_for_final_mirror(ai_message_id, attempts \\ 20)

  defp wait_for_final_mirror(ai_message_id, attempts) when attempts > 0 do
    case Repo.get_by(Entry, ai_message_id: ai_message_id) do
      %Entry{} = entry ->
        entry

      nil ->
        Process.sleep(50)
        wait_for_final_mirror(ai_message_id, attempts - 1)
    end
  end

  defp wait_for_final_mirror(ai_message_id, 0) do
    flunk("expected final mirror for ai_message_id=#{ai_message_id}")
  end

  defp dispatch_final_reply_outbox!(ai_message_id) do
    outbox =
      OutboxEntry
      |> where([outbox], outbox.ai_message_id == ^ai_message_id)
      |> Repo.all()
      |> Enum.find(fn outbox ->
        get_in(outbox.payload, ["metadata", "source"]) == "ai_gateway_final_reply" and
          get_in(outbox.payload, ["metadata", "delivery_target", "primary"]) != false
      end)

    case outbox do
      %OutboxEntry{} = outbox ->
        assert {:ok, %OutboxEntry{status: :succeeded}} =
                 SignalsGateway.dispatch_outbox(
                   outbox.agent_uid,
                   outbox.binding_name,
                   outbox.outbound_key,
                   outbox_adapter([:post_entry, :reply_entry, :edit_entry], fn outbox ->
                     {:ok,
                      %{
                        created_source_entry_id:
                          outbox.target_source_entry_id || "test-final-#{ai_message_id}",
                        raw_payload: %{"provider" => "test"}
                      }}
                   end)
                 )

        :ok

      nil ->
        flunk("expected final reply outbox for ai_message_id=#{ai_message_id}")
    end
  end

  defp checkback_attrs(agent_uid, overrides) do
    Map.merge(
      %{
        "agent_uid" => agent_uid,
        "session_id" => "mock:chat:schedule",
        "binding_name" => "bot",
        "tool_call_id" => "tool-check-1",
        "idempotency_key" => "checkback-key-1",
        "schedule" => %{"after" => %{"value" => 5, "unit" => "minute"}, "timezone" => "Etc/UTC"},
        "reason" => "Incident follow-up.",
        "check" => "Check the incident.",
        "context_summary" => "The incident was pending.",
        "reply_route" => %{
          "signal_channel_id" => "mock:chat:schedule",
          "provider_thread_id" => "thread-schedule",
          "source_entry_id" => "msg-source"
        },
        "source_provenance" => %{"test" => true}
      },
      stringify_keys(overrides)
    )
  end

  defp cron_attrs(agent_uid, overrides) do
    Map.merge(
      %{
        "agent_uid" => agent_uid,
        "owner_session_id" => "mock:chat:schedule",
        "binding_name" => "bot",
        "name" => "daily-digest",
        "schedule" => %{
          "kind" => "every",
          "every_ms" => 86_400_000,
          "anchor_at" => DateTime.to_iso8601(DateTime.add(@base_time, 1, :day))
        },
        "payload" => %{"task" => "digest"},
        "delivery" => %{
          "targets" => [
            %{
              "binding_name" => "bot",
              "signal_channel_id" => "mock:chat:schedule",
              "provider_thread_id" => "thread-schedule"
            }
          ]
        },
        "idempotency_key" => "cron-key-1"
      },
      stringify_keys(overrides)
    )
  end

  defp every_schedule(anchor_at) do
    %{
      "kind" => "every",
      "every_ms" => 60_000,
      "anchor_at" => DateTime.to_iso8601(anchor_at)
    }
  end

  defp ai_message_fixture(agent_uid, session_id \\ "mock:chat:schedule") do
    {:ok, conversation} = Conversations.ensure_conversation(agent_uid, session_id)

    Repo.insert!(%Message{
      subject_uid: agent_uid,
      conversation_id: conversation.id,
      type: "message",
      status: "complete",
      content: [],
      metadata: %{},
      inserted_at: @base_time,
      updated_at: @base_time
    })
  end

  defp binding_fixture(agent_uid, name, policy, adapter \\ "lark") do
    {:ok, binding} =
      SignalsGateway.upsert_binding(%{
        agent_uid: agent_uid,
        name: name,
        adapter: adapter,
        config_ref: "app-config://#{name}",
        filters: %{},
        unaddressed_group_message_policy: policy,
        unmatched_sender_policy: :create_standalone
      })

    binding
  end

  defp mock_adapter_context(agent_uid, binding_name) do
    AdapterContext.new(
      agent_uid: agent_uid,
      binding_name: binding_name,
      adapter: "mock-provider",
      user_name: "Mock Bot"
    )
  end

  defp emit_entry(agent_uid, binding_name, input, opts) do
    with {:ok, result} <- Ingress.emit_entry(agent_uid, binding_name, input, opts) do
      {:ok, maybe_finalize_test_inbound_batch(result)}
    end
  end

  defp maybe_finalize_test_inbound_batch(%{inbound_batch: %InboundBatch{} = batch} = result) do
    with {:ok, finalized_results} <-
           Ankole.SignalsGatewayFixtures.finalize_due_inbound_batch_events(
             now: batch.available_at
           ),
         %ActorEvent{} = actor_event <- finalized_actor_event(finalized_results, batch.id) do
      Map.put(result, :actor_event, actor_event)
    else
      _no_actor_event -> result
    end
  end

  defp maybe_finalize_test_inbound_batch(result), do: result

  defp finalized_actor_event(finalized_results, batch_id) do
    Enum.find_value(finalized_results, fn
      %{inbound_batch: %InboundBatch{id: ^batch_id}, actor_event: %ActorEvent{} = input} -> input
      _result -> nil
    end)
  end

  defp group_entry(overrides) do
    Map.merge(
      %{
        source_event_id: "evt-" <> Integer.to_string(System.unique_integer([:positive])),
        signal_channel_id: "lark:chat:group-a",
        source_entry_id: "msg-source",
        provider_thread_id: "thread-1",
        channel: %{kind: :im_group, reply_mode: :entry, name: "Ops"},
        text: "PING",
        explicit: false,
        author: %{principal_uid: "alice", id: "ou_alice", display_name: "Alice"},
        provider_time: @base_time
      },
      overrides
    )
  end

  defp lifecycle_entry(overrides) do
    Map.merge(
      %{
        source_event_id: "delete-1",
        signal_channel_id: "lark:chat:group-a",
        source_entry_id: "msg-source",
        provider_thread_id: "thread-1",
        channel: %{kind: :im_group, reply_mode: :entry, name: "Ops"}
      },
      overrides
    )
  end

  defp actor_commit_opts(opts) do
    Keyword.merge(
      [
        actor_event_id: Ecto.UUID.generate(),
        activation_uid:
          "test-activation-" <> Integer.to_string(System.unique_integer([:positive])),
        actor_epoch: 1,
        revision: 0
      ],
      opts
    )
  end

  defp append_runtime_actor_event(agent_uid, session_id, type, opts) do
    now = Keyword.fetch!(opts, :now)
    boundary_at = Keyword.get(opts, :boundary_at, now)
    source_event_id = "#{type}-#{System.unique_integer([:positive])}"

    SignalsGateway.append_actor_event(%{
      agent_uid: agent_uid,
      binding_name: "control-plane:test",
      session_id: session_id,
      source_event_id: source_event_id,
      type: type,
      available_at: now,
      payload: %{
        "specversion" => "1.0",
        "id" => source_event_id,
        "source" => "control-plane://test",
        "time" => DateTime.to_iso8601(now),
        "type" => type,
        "data" => %{
          "session" => %{
            "agent_uid" => agent_uid,
            "session_id" => session_id,
            "binding_name" => "control-plane:test"
          },
          "reset" => %{
            "kind" => "daily",
            "boundary_at" => DateTime.to_iso8601(boundary_at),
            "timezone" => "Etc/UTC",
            "local_time" => "04:30"
          }
        }
      }
    })
  end

  defp admit_worker(route, overrides \\ %{}) do
    fields =
      Map.merge(
        %{
          worker_id: "worker-" <> route,
          incarnation_id: "incarnation-" <> route,
          runtime: "bun",
          version: "test",
          capacity: %{"available_turn_slots" => 4}
        },
        overrides
      )

    {capacity, fields} = Map.pop(fields, :capacity)
    capacity = capacity || %{}
    available_turn_slots = Map.get(capacity, "available_turn_slots", 0)
    max_turns = Map.get(capacity, "max_turns", available_turn_slots)

    ActorRuntime.admit_worker_ready(
      struct!(
        FabricProto.AgentComputerWorkerReady,
        fields
        |> Map.put(:max_turns, max_turns)
        |> Map.put(:available_turn_slots, available_turn_slots)
      ),
      %{authenticated?: true, transport_route: route}
    )
  end

  defp unique_route do
    "local-schedule-test-route-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp schedule_rpc(action, request, turn, route) do
    {module, function, scope, _request_mod, _response_mod} =
      Map.fetch!(Ankole.SignalsGateway.ActorRuntime.RPCLane.operations(), "schedule." <> action)

    effect = if scope == :turn_read, do: :read, else: :write
    ctx = %{route: route, request_id: "schedule-test-#{System.unique_integer([:positive])}"}

    with {:ok, turn_ref} <- TurnRef.from_proto(turn_proto_ref(turn)),
         :ok <- WorkerRouteAuth.authorize_turn_route(turn_ref, route, effect) do
      apply(module, function, [turn_ref, request, ctx])
    else
      {:error, reason} -> {:error, schedule_rpc_error(reason)}
    end
  end

  defp schedule_rpc_error(reason) do
    %{
      "request_id" => "",
      "code" => schedule_rpc_error_code(reason),
      "message" => schedule_rpc_error_message(reason),
      "details_json" => %{"reason" => inspect(reason)}
    }
  end

  defp schedule_rpc_error_code(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp schedule_rpc_error_code({reason, _details}) when is_atom(reason),
    do: Atom.to_string(reason)

  defp schedule_rpc_error_code(_reason), do: "schedule_rpc_failed"

  defp schedule_rpc_error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp schedule_rpc_error_message({reason, details}), do: "#{reason}: #{inspect(details)}"
  defp schedule_rpc_error_message(reason), do: inspect(reason)

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end
end
