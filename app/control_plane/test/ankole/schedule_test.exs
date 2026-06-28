defmodule Ankole.ScheduleTest do
  use Ankole.DataCase, async: false

  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.AIAgent.Schemas.Message
  alias Ankole.Actors
  alias Ankole.Actors.ActorInput
  alias Ankole.Actors.ActorInputConsumption
  alias Ankole.ActorRuntime
  alias Ankole.ActorRuntime.WorkerRouteAuth
  alias Ankole.ActorRuntime.Schemas.ActorInputDelivery
  alias Ankole.ActorRuntime.Transport.Broker
  alias Ankole.PluginFixtures.MockSignalProvider.Inbound, as: MockInbound
  alias Ankole.PluginFixtures.MockSignalProvider.Outbox, as: MockOutbox
  alias Ankole.Repo
  alias Ankole.Schedule
  alias Ankole.Schedule.RPCBroker
  alias Ankole.Schedule.Schemas.ScheduledEvent
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.AdapterContext
  alias Ankole.SignalsGateway.InboundBatch
  alias Ankole.SignalsGateway.OutboxEntry

  @base_time ~U[2026-06-27 08:00:00.000000Z]
  @long_lease_seconds 604_800

  describe "durable schedule domain" do
    test "check_back_later creates one wake edge and fires one actor input idempotently" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      due_at = DateTime.add(@base_time, 5, :minute)

      attrs =
        checkback_attrs(agent.uid,
          schedule: %{"at" => DateTime.to_iso8601(due_at), "timezone" => "Etc/UTC"}
        )

      assert {:ok, %{status: :scheduled, scheduled_event: event}} =
               Schedule.create_check_back_later(attrs, now: @base_time)

      assert event.due_at == due_at
      assert event.provider_entry_id == "msg-source"

      assert {:ok, %{status: :already_scheduled, scheduled_event: duplicate}} =
               Schedule.create_check_back_later(attrs, now: @base_time)

      assert duplicate.id == event.id

      assert {:ok, %{status: :fired, actor_input: input}} =
               Schedule.fire_due_event(event.id, now: due_at)

      assert input.type == "check_back_later.wakeup"
      assert input.ingress_event_id == "check_back_later:#{event.id}:wakeup"
      assert get_in(input.payload, ["data", "wake_payload", "check"]) == "Check the incident."

      assert {:ok, %{status: :noop}} = Schedule.fire_due_event(event.id, now: due_at)
      assert Repo.aggregate(ActorInput, :count) == 1
    end

    test "cron fire coalesces missed backlog and carries configured delivery route" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      first_slot = DateTime.add(@base_time, 1, :minute)
      late_fire = DateTime.add(@base_time, 10, :minute)

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
                 now: @base_time
               )

      assert [event] = Schedule.list_cron_runs(schedule.id, 10)
      assert event.due_at == first_slot
      assert event.signal_channel_id == "mock:chat:schedule"
      assert event.provider_thread_id == "thread-schedule"

      assert {:ok, %{status: :fired, actor_input: input}} =
               Schedule.fire_due_event(event.id, now: late_fire)

      assert input.type == "cron.fire"
      assert input.signal_channel_id == "mock:chat:schedule"
      assert input.provider_entry_id == nil

      reloaded = Schedule.get_cron_schedule(schedule.id) |> elem(1)
      assert reloaded.last_fire_at == first_slot
      assert reloaded.next_fire_at == DateTime.add(@base_time, 11, :minute)

      scheduled_events =
        schedule.id
        |> Schedule.list_cron_runs(10)
        |> Enum.filter(&(&1.status == "scheduled"))

      assert length(scheduled_events) == 1
      assert hd(scheduled_events).cron_fire_slot_at == DateTime.add(@base_time, 11, :minute)
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

    test "cancelled checkback does not fire after source entry tombstone" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{actor_input: source_input}} =
               emit_entry(agent.uid, "bot", group_entry(%{explicit: true}), now: @base_time)

      assert {:ok, _consumed} =
               Actors.consume_actor_input(
                 agent.uid,
                 "bot",
                 source_input.ingress_event_id,
                 actor_commit_opts(consumed_at: DateTime.add(@base_time, 1, :second))
               )

      due_at = DateTime.add(@base_time, 5, :minute)

      assert {:ok, %{scheduled_event: event}} =
               Schedule.create_check_back_later(
                 checkback_attrs(agent.uid,
                   session_id: source_input.session_id,
                   reply_route: %{
                     "signal_channel_id" => source_input.signal_channel_id,
                     "provider_thread_id" => source_input.provider_thread_id,
                     "provider_entry_id" => source_input.provider_entry_id
                   },
                   source_actor_input_id: source_input.id,
                   schedule: %{"at" => DateTime.to_iso8601(due_at), "timezone" => "Etc/UTC"}
                 ),
                 now: @base_time
               )

      assert {:ok, %{lifecycle_inputs: [lifecycle_input]}} =
               SignalsGateway.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{ingress_event_id: "delete-source"}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, %{status: :entry_lifecycle_recorded, cancelled_checkbacks: 1}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 3, :second))

      refute Repo.get(ActorInput, lifecycle_input.id)
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

      assert {:ok, %{actor_input: source_input}} =
               emit_entry(agent.uid, "bot", group_entry(%{explicit: true}), now: @base_time)

      assert {:ok, %{llm_turn: _llm_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}
      turn_ref = envelope["body"]["turn_start"]["turn"]

      reply_route = %{
        "binding_name" => source_input.binding_name,
        "signal_channel_id" => source_input.signal_channel_id,
        "provider_thread_id" => source_input.provider_thread_id,
        "provider_entry_id" => source_input.provider_entry_id
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

      assert Repo.get!(ScheduledEvent, scheduled_event_id).source_actor_input_id ==
               source_input.id

      bad_reply_route = %{reply_route | "provider_entry_id" => "not-current-entry"}

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
                   ingress_event_id: "mock-entry-1",
                   signal_channel_id: "mock:chat:e2e",
                   provider_entry_id: "mock-message-1",
                   provider_thread_id: "mock-thread-1",
                   text: "Please check in five minutes whether deploy finished.",
                   explicit: true,
                   now: @base_time,
                   provider_time: @base_time
                 },
                 [consumer]
               )

      %{actor_input: source_input} = maybe_finalize_test_inbound_batch(receive_result)

      assert {:ok, _consumed} =
               Actors.consume_actor_input(
                 agent.uid,
                 "mock-provider",
                 source_input.ingress_event_id,
                 actor_commit_opts(consumed_at: DateTime.add(@base_time, 1, :second))
               )

      due_at = DateTime.add(@base_time, 5, :minute)

      assert {:ok, %{scheduled_event: event}} =
               Schedule.create_check_back_later(
                 checkback_attrs(agent.uid,
                   session_id: source_input.session_id,
                   binding_name: "mock-provider",
                   reply_route: %{
                     "signal_channel_id" => source_input.signal_channel_id,
                     "provider_thread_id" => source_input.provider_thread_id,
                     "provider_entry_id" => source_input.provider_entry_id
                   },
                   source_actor_input_id: source_input.id,
                   schedule: %{"at" => DateTime.to_iso8601(due_at), "timezone" => "Etc/UTC"}
                 ),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, %{actor_input: wake_input}} = Schedule.fire_due_event(event.id, now: due_at)

      route = unique_route()
      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{llm_turn: llm_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(due_at, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}
      turn_start = envelope["body"]["turn_start"]
      turn_ref = turn_start["turn"]
      input_ids = Enum.map(turn_start["inputs"], & &1["actor_input_id"])

      assert input_ids == [wake_input.id]
      assert Repo.get!(LlmTurn, llm_turn.id).kind == "checkback_generation"

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => turn_ref,
                   "accepted_actor_input_ids" => input_ids
                 }
               })

      assert {:ok, %{status: :committed}} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => turn_ref,
                   "messages" => [],
                   "reply" => %{"text" => "Deployment finished cleanly."}
                 }
               })

      outbox = Repo.one!(from(outbox in OutboxEntry))
      assert outbox.operation == :reply
      assert outbox.source_actor_input_id == wake_input.id
      assert outbox.signal_channel_id == "mock:chat:e2e"
      assert outbox.source_provider_entry_id == "mock-message-1"

      MockOutbox.put_recipient(self())

      assert [{:ok, %OutboxEntry{status: :succeeded}}] =
               SignalsGateway.dispatch_due_outbox(fn _outbox -> MockOutbox end,
                 now: DateTime.add(due_at, 2, :second)
               )

      assert_receive {:mock_provider_outbox_sent, %OutboxEntry{} = sent_outbox}
      assert sent_outbox.outbound_key == outbox.outbound_key
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

      assert {:ok, %{actor_input: input}} = Schedule.fire_due_event(event.id, now: due_at)

      assert {:ok, %{llm_turn: llm_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(due_at, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}
      turn_start = envelope["body"]["turn_start"]
      turn_ref = turn_start["turn"]
      input_ids = Enum.map(turn_start["inputs"], & &1["actor_input_id"])

      assert input_ids == [input.id]

      assert [%{"type" => "check_back_later.wakeup", "signal_channel_id" => "mock:chat:schedule"}] =
               turn_start["inputs"]

      persisted_turn = Repo.get!(LlmTurn, llm_turn.id)
      assert persisted_turn.kind == "checkback_generation"
      assert persisted_turn.request_context["turn_mode"] == "check_back_later"
      assert persisted_turn.request_context["silent_success_allowed"] == true

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => turn_ref,
                   "accepted_actor_input_ids" => input_ids
                 }
               })

      assert {:ok, %{status: :schedule_silent, assistant_message: nil}} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => turn_ref,
                   "messages" => [],
                   "silent_success" => true
                 }
               })

      refute Repo.get(ActorInput, input.id)
      assert Repo.aggregate(ActorInputConsumption, :count) == 1
      assert Repo.aggregate(OutboxEntry, :count) == 0
      assert Repo.aggregate(ActorInputDelivery, :count) == 0
      assert Repo.get!(LlmTurn, llm_turn.id).response["silent_success"] == true
    end

    test "cron fire starts a scheduled_task turn and posts to configured delivery" do
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
      assert {:ok, %{actor_input: input}} = Schedule.fire_due_event(event.id, now: first_slot)

      assert {:ok, %{llm_turn: llm_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(first_slot, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}
      turn_start = envelope["body"]["turn_start"]
      turn_ref = turn_start["turn"]
      input_ids = Enum.map(turn_start["inputs"], & &1["actor_input_id"])

      assert Repo.get!(LlmTurn, llm_turn.id).kind == "scheduled_task"
      assert Repo.get!(LlmTurn, llm_turn.id).request_context["turn_mode"] == "cron"

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => turn_ref,
                   "accepted_actor_input_ids" => input_ids
                 }
               })

      assert {:ok, %{status: :committed, assistant_message: %Message{}}} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => turn_ref,
                   "messages" => [],
                   "reply" => %{"text" => "Daily digest is ready."}
                 }
               })

      outbox = Repo.one!(from(outbox in OutboxEntry))
      assert outbox.source_actor_input_id == input.id
      assert outbox.operation == :post
      assert outbox.signal_channel_id == "mock:chat:schedule"
      assert outbox.provider_thread_id == "thread-schedule"
      assert outbox.target_provider_entry_id == nil
      assert outbox.payload == %{"text" => "Daily digest is ready."}
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
      assert {:ok, %{actor_input: _input}} = Schedule.fire_due_event(event.id, now: first_slot)

      assert {:ok, %{llm_turn: _llm_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(first_slot, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}
      turn_ref = envelope["body"]["turn_start"]["turn"]

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
      assert {:ok, %{actor_input: input}} = Schedule.fire_due_event(event.id, now: first_slot)

      assert {:ok, %{llm_turn: llm_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(first_slot, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}
      turn_start = envelope["body"]["turn_start"]
      turn_ref = turn_start["turn"]
      input_ids = Enum.map(turn_start["inputs"], & &1["actor_input_id"])

      assert Repo.get!(LlmTurn, llm_turn.id).request_context["silent_success_allowed"] == true

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => turn_ref,
                   "accepted_actor_input_ids" => input_ids
                 }
               })

      assert {:ok, %{status: :schedule_silent, assistant_message: nil}} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => turn_ref,
                   "messages" => [],
                   "silent_success" => true
                 }
               })

      refute Repo.get(ActorInput, input.id)
      assert Repo.aggregate(OutboxEntry, :count) == 0
    end

    test "session reset cancels overdue pending cron fires and rearms from reset time" do
      %{principal: agent} = agent_fixture()
      session_id = "mock:chat:schedule"
      first_slot = DateTime.add(@base_time, 1, :minute)
      reset_at = DateTime.add(@base_time, 2, :minute)

      assert {:ok, _conversation} = ActorRuntime.ensure_conversation(agent.uid, session_id)

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

      assert {:ok, reset_input} =
               append_runtime_actor_input(agent.uid, session_id, "session.reset_due",
                 now: reset_at,
                 boundary_at: reset_at
               )

      assert {:ok,
              %{
                status: :session_reset,
                reset_input: ^reset_input,
                cron_reset: %{cancelled_events: 1, rearmed_schedules: 1}
              }} =
               ActorRuntime.process_ready_inputs_once(now: reset_at)

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
               credential: "sk-test",
               base_url: "https://openrouter.ai/api/v1",
               connection_options: %{}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: provider_id,
               model: "google/gemini-3.5-flash"
             })

    fixture
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
          "provider_entry_id" => "msg-source"
        },
        "source_llm_turn_id" => Ecto.UUID.generate(),
        "source_actor_input_id" => Ecto.UUID.generate(),
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
        "created_by" => %{"kind" => "test"},
        "failure_policy" => %{}
      },
      stringify_keys(overrides)
    )
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
    with {:ok, result} <- SignalsGateway.emit_entry(agent_uid, binding_name, input, opts) do
      {:ok, maybe_finalize_test_inbound_batch(result)}
    end
  end

  defp maybe_finalize_test_inbound_batch(%{inbound_batch: %InboundBatch{} = batch} = result) do
    with {:ok, finalized_results} <-
           SignalsGateway.finalize_due_inbound_batches(now: batch.available_at),
         %ActorInput{} = actor_input <- finalized_actor_input(finalized_results, batch.id) do
      Map.put(result, :actor_input, actor_input)
    else
      _no_actor_input -> result
    end
  end

  defp maybe_finalize_test_inbound_batch(result), do: result

  defp finalized_actor_input(finalized_results, batch_id) do
    Enum.find_value(finalized_results, fn
      %{inbound_batch: %InboundBatch{id: ^batch_id}, actor_input: %ActorInput{} = input} -> input
      _result -> nil
    end)
  end

  defp group_entry(overrides) do
    Map.merge(
      %{
        ingress_event_id: "evt-" <> Integer.to_string(System.unique_integer([:positive])),
        signal_channel_id: "lark:chat:group-a",
        provider_entry_id: "msg-source",
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
        ingress_event_id: "delete-1",
        signal_channel_id: "lark:chat:group-a",
        provider_entry_id: "msg-source",
        provider_thread_id: "thread-1",
        channel: %{kind: :im_group, reply_mode: :entry, name: "Ops"}
      },
      overrides
    )
  end

  defp actor_commit_opts(opts) do
    Keyword.merge(
      [
        llm_turn_id: Ecto.UUID.generate(),
        activation_uid:
          "test-activation-" <> Integer.to_string(System.unique_integer([:positive])),
        actor_epoch: 1,
        revision: 0
      ],
      opts
    )
  end

  defp append_runtime_actor_input(agent_uid, session_id, type, opts) do
    now = Keyword.fetch!(opts, :now)
    boundary_at = Keyword.get(opts, :boundary_at, now)
    ingress_event_id = "#{type}-#{System.unique_integer([:positive])}"

    Actors.append_actor_input(%{
      agent_uid: agent_uid,
      binding_name: "control-plane:test",
      session_id: session_id,
      ingress_event_id: ingress_event_id,
      type: type,
      available_at: now,
      payload: %{
        "specversion" => "1.0",
        "id" => ingress_event_id,
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
    RPCBroker.handle_request(action, &WorkerRouteAuth.authorize_turn_route/3, request, route)
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end
end
