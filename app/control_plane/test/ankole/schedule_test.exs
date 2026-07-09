defmodule Ankole.ScheduleTest do
  use Ankole.DataCase, async: false

  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Actors
  alias Ankole.Actors.ActorEvent
  alias Ankole.ActorRuntime
  alias Ankole.ActorRuntime.TurnRef
  alias Ankole.ActorRuntime.WorkerRouteAuth
  alias Ankole.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.ActorRuntime.Transport.Broker
  alias Ankole.PluginFixtures.MockSignalProviderPlugin
  alias Ankole.PluginFixtures.MockSignalProvider.Inbound, as: MockInbound
  alias Ankole.Plugins.Spec
  alias Ankole.Repo
  alias Ankole.Schedule
  alias Ankole.Schedule.RPCBroker
  alias Ankole.Schedule.Schemas.ScheduledEvent
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.AdapterContext
  alias Ankole.SignalsGateway.InboundBatch
  alias Ankole.SignalsGateway.Ingress
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.Entry

  import Ankole.ActorRuntimeCase, only: [complete_actor_event: 4, process_ready_events_once: 1]

  @base_time DateTime.utc_now(:microsecond)
  @long_lease_seconds 604_800

  setup :use_mock_signal_provider_plugin

  describe "durable schedule domain" do
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
               perform_job(Ankole.ActorRuntime.Jobs.FireScheduledEvent, %{
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
      assert event.due_at == first_slot
      assert event.signal_channel_id == "mock:chat:schedule"
      assert event.provider_thread_id == "thread-schedule"
      assert event.origin_ai_message_id == origin_ai_message.id

      assert {:ok, %{status: :fired, actor_event: input}} =
               Schedule.fire_due_event(event.id, now: late_fire)

      assert input.type == "cron.fire"
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
      turn_ref = envelope["body"]["turn_start"]["turn"]

      assert {:ok, conversation} =
               StatefulResponses.ensure_conversation(agent.uid, source_event.session_id)

      assert {:ok, generating_message} =
               StatefulResponses.start_response_run(%{
                 agent_uid: agent.uid,
                 conversation_id: conversation.id,
                 actor_event_id: turn_ref["actor_event_id"]
               })

      reply_route = %{
        "binding_name" => source_event.binding_name,
        "signal_channel_id" => source_event.signal_channel_id,
        "provider_thread_id" => source_event.provider_thread_id,
        "source_entry_id" => source_event.source_entry_id
      }

      request = %{
        "request_id" => "schedule-rpc-ok",
        "turn_ref" => turn_ref,
        "tool_call_id" => "checkback-call-1",
        "idempotency_key" => "schedule-rpc-checkback-1",
        "schedule" => %{"after" => %{"value" => 5, "unit" => "minute"}, "timezone" => "Etc/UTC"},
        "reason" => "Deployment is still running.",
        "check" => "Ask whether the deployment finished.",
        "reply_route" => reply_route
      }

      assert {:ok,
              %{
                "status" => "scheduled",
                "scheduled_event_id" => scheduled_event_id,
                "timezone" => "Etc/UTC"
              }} = schedule_rpc("check_back_later.create", request, route)

      scheduled_event = Repo.get!(ScheduledEvent, scheduled_event_id)
      assert scheduled_event.source_actor_event_id == source_event.id
      assert scheduled_event.origin_ai_message_id == generating_message.id

      bad_reply_route = %{reply_route | "source_entry_id" => "not-current-entry"}

      assert {:error, %{"code" => "reply_route_not_in_turn"}} =
               schedule_rpc(
                 "check_back_later.create",
                 %{
                   request
                   | "idempotency_key" => "schedule-rpc-checkback-bad-route",
                     "reply_route" => bad_reply_route
                 },
                 route
               )

      cron_request = %{
        "request_id" => "schedule-rpc-cron-ok",
        "turn_ref" => turn_ref,
        "binding_name" => source_event.binding_name,
        "name" => "dashboard-route-cron",
        "schedule" => %{
          "kind" => "cron",
          "expression" => "0 7 * * *",
          "timezone" => "Asia/Shanghai"
        },
        "payload" => %{"task" => "dashboard-check"},
        "delivery" => %{
          "signal_channel_id" => source_event.signal_channel_id,
          "provider_thread_id" => source_event.provider_thread_id
        },
        "idempotency_key" => "schedule-rpc-cron-1"
      }

      assert {:ok, %{"status" => "created", "schedule" => %{"id" => cron_schedule_id}}} =
               schedule_rpc("cron.add", cron_request, route)

      bad_cron_delivery = %{
        "signal_channel_id" => "not-current-channel",
        "provider_thread_id" => source_event.provider_thread_id
      }

      assert {:error, %{"code" => "reply_route_not_in_turn"}} =
               schedule_rpc(
                 "cron.add",
                 %{
                   cron_request
                   | "request_id" => "schedule-rpc-cron-bad-route",
                     "idempotency_key" => "schedule-rpc-cron-bad-route",
                     "delivery" => bad_cron_delivery
                 },
                 route
               )

      assert {:error, %{"code" => "reply_route_not_in_turn"}} =
               schedule_rpc(
                 "cron.update",
                 %{
                   "request_id" => "schedule-rpc-cron-update-bad-route",
                   "turn_ref" => turn_ref,
                   "cron_schedule_id" => cron_schedule_id,
                   "updates" => %{"delivery" => bad_cron_delivery}
                 },
                 route
               )

      assert {:error, %{"code" => "worker_not_assigned_to_turn"}} =
               schedule_rpc(
                 "check_back_later.create",
                 %{request | "idempotency_key" => "schedule-rpc-checkback-wrong-worker"},
                 "wrong-worker-route"
               )
    end

    test "mock IM checkback story wakes later and replies through the provider outbox" do
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
                   source_event_id: "mock-entry-1",
                   signal_channel_id: "mock:chat:e2e",
                   source_entry_id: "mock-message-1",
                   provider_thread_id: "mock-thread-1",
                   text: "Please check in five minutes whether deploy finished.",
                   explicit: true,
                   now: @base_time,
                   provider_time: @base_time
                 },
                 [consumer]
               )

      %{actor_event: source_event} = maybe_finalize_test_inbound_batch(receive_result)

      assert {:ok, _consumed} =
               complete_actor_event(
                 agent.uid,
                 "mock-provider",
                 source_event.source_event_id,
                 actor_commit_opts(completed_at: DateTime.add(@base_time, 1, :second))
               )

      due_at = DateTime.add(@base_time, 5, :minute)

      assert {:ok, %{scheduled_event: event}} =
               Schedule.create_check_back_later(
                 checkback_attrs(agent.uid,
                   session_id: source_event.session_id,
                   binding_name: "mock-provider",
                   reply_route: %{
                     "signal_channel_id" => source_event.signal_channel_id,
                     "provider_thread_id" => source_event.provider_thread_id,
                     "source_entry_id" => source_event.source_entry_id
                   },
                   source_actor_event_id: source_event.id,
                   schedule: %{"at" => DateTime.to_iso8601(due_at), "timezone" => "Etc/UTC"}
                 ),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, %{actor_event: wake_input}} = Schedule.fire_due_event(event.id, now: due_at)

      route = unique_route()
      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               process_ready_events_once(
                 now: DateTime.add(due_at, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}
      turn_start = envelope["body"]["turn_start"]
      turn_ref = turn_start["turn"]
      input_ids = Enum.map(List.wrap(turn_start["actor_event"]), & &1["actor_event_id"])

      assert input_ids == [wake_input.id]

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => turn_ref
                 }
               })

      committed = complete_turn_via_aigateway!(turn_ref, "Deployment finished cleanly.")

      dispatch_final_reply_outbox!(committed.id)
      mirror = wait_for_final_mirror(committed.id)
      assert mirror.signal_channel_id == "mock:chat:e2e"
      assert mirror.text == "Deployment finished cleanly."
      assert mirror.ai_message_id == committed.id
      assert mirror.metadata["actor_event_id"] == wake_input.id
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
      turn_start = envelope["body"]["turn_start"]
      turn_ref = turn_start["turn"]

      assert turn_ref["actor"]["session_id"] == source_event.session_id

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{"turn" => turn_ref}
               })

      assert {:ok, %{"status" => "created", "schedule" => %{"id" => cron_schedule_id}}} =
               schedule_rpc(
                 "cron.add",
                 %{
                   "request_id" => "dashboard-cron-add",
                   "turn_ref" => turn_ref,
                   "binding_name" => "mock-provider",
                   "name" => "dashboard-morning-check",
                   "schedule" => %{
                     "kind" => "cron",
                     "expression" => "0 7 * * *",
                     "timezone" => "Asia/Shanghai"
                   },
                   "payload" => %{
                     "task" => "dashboard_status_check",
                     "dashboard_url" => "https://status.internal",
                     "services" => ["api", "billing", "search"],
                     "report_format" =>
                       "one line per service: green, or what's off and since when"
                   },
                   "delivery" => %{
                     "signal_channel_id" => source_event.signal_channel_id,
                     "provider_thread_id" => source_event.provider_thread_id
                   },
                   "idempotency_key" => "dashboard-cron-story"
                 },
                 route
               )

      scheduled_ack =
        complete_turn_via_aigateway!(
          turn_ref,
          "Scheduled the dashboard check for 07:00 Asia/Shanghai."
        )

      dispatch_final_reply_outbox!(scheduled_ack.id)
      assert wait_for_final_mirror(scheduled_ack.id).signal_channel_id == "mock:chat:dashboard"

      [scheduled_event] = Schedule.list_cron_runs(cron_schedule_id, 10)
      due_now = DateTime.add(DateTime.utc_now(:microsecond), -1, :second)

      scheduled_event
      |> ScheduledEvent.changeset(%{due_at: due_now})
      |> Repo.update!()

      assert :ok =
               perform_job(Ankole.ActorRuntime.Jobs.FireScheduledEvent, %{
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

      cron_turn_start = cron_envelope["body"]["turn_start"]
      cron_turn_ref = cron_turn_start["turn"]

      assert cron_turn_start["request_context"]["turn_mode"] == "cron"

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{"turn" => cron_turn_ref}
               })

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

    test "checkback wakeup starts a checkback_generation turn that can finish silently" do
      %{principal: agent} = agent_fixture()
      route = unique_route()
      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      due_at = DateTime.add(@base_time, 1, :minute)

      assert {:ok, %{scheduled_event: event}} =
               Schedule.create_check_back_later(
                 checkback_attrs(agent.uid,
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
      turn_start = envelope["body"]["turn_start"]
      turn_ref = turn_start["turn"]
      input_ids = Enum.map(List.wrap(turn_start["actor_event"]), & &1["actor_event_id"])

      assert input_ids == [input.id]

      assert [%{"type" => "check_back_later.wakeup", "signal_channel_id" => "mock:chat:schedule"}] =
               List.wrap(turn_start["actor_event"])

      assert turn_start["request_context"]["turn_mode"] == "check_back_later"
      assert turn_start["request_context"]["silent_success_allowed"] == true

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => turn_ref
                 }
               })

      assert {:ok, %{status: :noop_completed}} =
               ActorRuntime.handle_turn_noop_completed(%{
                 "turn_noop_completed" => %{
                   "turn" => turn_ref,
                   "reason" => "schedule_silent_success"
                 }
               })

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
      turn_start = envelope["body"]["turn_start"]
      turn_ref = turn_start["turn"]

      assert turn_start["request_context"]["turn_mode"] == "cron"

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => turn_ref
                 }
               })

      assert %Message{} =
               committed = complete_turn_via_aigateway!(turn_ref, "Daily digest is ready.")

      dispatch_final_reply_outbox!(committed.id)
      mirror = wait_for_final_mirror(committed.id)
      assert mirror.signal_channel_id == "mock:chat:schedule"
      assert mirror.text == "Daily digest is ready."
      assert mirror.ai_message_id == committed.id
      assert mirror.metadata["actor_event_id"] == input.id
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
      turn_ref = envelope["body"]["turn_start"]["turn"]

      assert {:ok, %{"runs" => [projected_run | _rest]}} =
               schedule_rpc(
                 "cron.runs",
                 %{
                   "request_id" => "cron-runs-model-projection",
                   "turn_ref" => turn_ref,
                   "cron_schedule_id" => schedule.id
                 },
                 route
               )

      assert projected_run["cron_schedule_id"] == schedule.id
      assert Map.has_key?(projected_run, "wake_payload")
      refute Map.has_key?(projected_run, "source_provenance")
      refute Map.has_key?(projected_run, "oban_job_id")
      refute Map.has_key?(projected_run, "fire_attempts")
      refute Map.has_key?(projected_run, "last_fire_error")

      assert {:error, %{"code" => "cron_origin_broad_cron_mutation_denied"}} =
               schedule_rpc(
                 "cron.pause",
                 %{
                   "request_id" => "cron-origin-pause-denied",
                   "turn_ref" => turn_ref,
                   "cron_schedule_id" => schedule.id
                 },
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
                     "signal_channel_id" => "mock:chat:schedule",
                     "provider_thread_id" => "thread-schedule",
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
      turn_start = envelope["body"]["turn_start"]
      turn_ref = turn_start["turn"]

      assert turn_start["request_context"]["silent_success_allowed"] == true

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => turn_ref
                 }
               })

      assert {:ok, %{status: :noop_completed}} =
               ActorRuntime.handle_turn_noop_completed(%{
                 "turn_noop_completed" => %{
                   "turn" => turn_ref,
                   "reason" => "schedule_silent_success"
                 }
               })

      # Actor events are durable — completion records the terminal timestamp.
      assert Repo.get(ActorEvent, input.id)
      assert Repo.aggregate(OutboxEntry, :count) == 0
    end

    test "session reset cancels overdue pending cron fires and rearms from reset time" do
      %{principal: agent} = agent_fixture()
      session_id = "mock:chat:schedule"
      first_slot = DateTime.add(@base_time, 1, :minute)
      reset_at = DateTime.add(@base_time, 2, :minute)

      assert {:ok, _conversation} =
               Ankole.AIGateway.Conversations.ensure_conversation(agent.uid, session_id)

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

      [old_event] = Schedule.list_cron_runs(schedule.id, 10)
      assert old_event.due_at == first_slot

      assert {:ok, reset_event} =
               append_runtime_actor_event(agent.uid, session_id, "session.reset_due",
                 now: reset_at,
                 boundary_at: reset_at
               )

      assert {:ok,
              %{
                status: :session_reset,
                reset_event: ^reset_event,
                cron_reset: %{cancelled_events: 1, rearmed_schedules: 1}
              }} =
               process_ready_events_once(now: reset_at)

      assert Repo.get!(ScheduledEvent, old_event.id).status == "cancelled"
      assert {:ok, %{status: :noop}} = Schedule.fire_due_event(old_event.id, now: reset_at)

      reloaded = Schedule.get_cron_schedule(schedule.id) |> elem(1)
      assert reloaded.next_fire_at == DateTime.add(@base_time, 3, :minute)

      scheduled_runs =
        schedule.id
        |> Schedule.list_cron_runs(10)
        |> Enum.filter(&(&1.status == "scheduled"))

      assert Enum.map(scheduled_runs, & &1.due_at) == [DateTime.add(@base_time, 3, :minute)]
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
               connection_options: %{
                 "api_key" => "sk-test"
               }
             })

    :ok = Ankole.ActorRuntimeCase.cache_actor_runtime_models(provider_id)

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
        disabled_ids: MapSet.new()
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
    agent_uid = get_in(turn_ref, ["actor", "agent_uid"])
    session_id = get_in(turn_ref, ["actor", "session_id"])
    actor_event_id = Map.fetch!(turn_ref, "actor_event_id")

    {:ok, conversation} = StatefulResponses.ensure_conversation(agent_uid, session_id)

    {:ok, run} =
      StatefulResponses.start_response_run(%{
        agent_uid: agent_uid,
        conversation_id: conversation.id,
        actor_event_id: actor_event_id
      })

    {:ok, committed} =
      StatefulResponses.commit_complete(run, [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => text}]
        }
      ])

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
    case Repo.get_by(OutboxEntry, outbound_key: "ai-reply:#{ai_message_id}") do
      %OutboxEntry{} = outbox ->
        assert {:ok, %OutboxEntry{status: :succeeded}} =
                 SignalsGateway.dispatch_outbox(
                   outbox.agent_uid,
                   outbox.binding_name,
                   outbox.outbound_key,
                   %{
                     capabilities: [:post_entry, :reply_entry, :edit_entry],
                     send: fn outbox ->
                       {:ok,
                        %{
                          created_source_entry_id:
                            outbox.target_source_entry_id || "test-final-#{ai_message_id}",
                          raw_payload: %{"provider" => "test"}
                        }}
                     end
                   }
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
        "session_id" => "mock:chat:schedule",
        "binding_name" => "bot",
        "name" => "daily-digest",
        "schedule" => %{
          "kind" => "every",
          "every_ms" => 86_400_000,
          "anchor_at" => DateTime.to_iso8601(DateTime.add(@base_time, 1, :day))
        },
        "payload" => %{"task" => "digest"},
        "delivery" => %{
          "signal_channel_id" => "mock:chat:schedule",
          "provider_thread_id" => "thread-schedule"
        },
        "idempotency_key" => "cron-key-1",
        "failure_policy" => %{}
      },
      stringify_keys(overrides)
    )
  end

  defp ai_message_fixture(agent_uid, session_id \\ "mock:chat:schedule") do
    {:ok, conversation} = StatefulResponses.ensure_conversation(agent_uid, session_id)

    Repo.insert!(%Message{
      agent_uid: agent_uid,
      conversation_id: conversation.id,
      type: "message",
      role: "assistant",
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
        unaddressed_group_message_policy: policy
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

    Actors.append_actor_event(%{
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
    ActorRuntime.admit_worker_ready(
      Map.merge(
        %{
          worker_id: "worker-" <> route,
          runtime: "bun",
          version: "test",
          capacity: %{"available_turn_slots" => 4}
        },
        overrides
      ),
      %{authenticated?: true, transport_route: route}
    )
  end

  defp unique_route do
    "local-schedule-test-route-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp schedule_rpc(action, request, route) do
    with {:ok, turn_ref} <- TurnRef.from_request(request, :turn_ref),
         :ok <- WorkerRouteAuth.authorize_turn_route(turn_ref, route, schedule_rpc_effect(action)) do
      RPCBroker.handle_request(action, turn_ref, request, route)
    else
      {:error, reason} -> {:error, schedule_rpc_error(reason)}
    end
  end

  defp schedule_rpc_effect(action) when action in ["cron.list", "cron.get", "cron.runs"],
    do: :read

  defp schedule_rpc_effect(_action), do: :write

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
