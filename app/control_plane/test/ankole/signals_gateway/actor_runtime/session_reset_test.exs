defmodule Ankole.SignalsGateway.ActorRuntime.SessionResetTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.Schedule

  setup {Ankole.SignalsGateway.ActorRuntimeCase, :use_mock_signal_provider_plugin}

  describe "session reset inputs" do
    test "daily reset enqueuer uses AppConfigure timezone and the 04:30 boundary" do
      %{principal: agent} = agent_fixture()
      session_id = "manual-session:daily-reset"

      assert {:ok, "Asia/Shanghai"} = SystemConfig.put_timezone("Asia/Shanghai")

      assert {:ok, conversation} =
               Ankole.AIGateway.Conversations.ensure_conversation(agent.uid, session_id)

      Repo.update_all(
        from(stored in Conversation, where: stored.id == ^conversation.id),
        set: [
          inserted_at: ~U[2026-06-25 20:00:00.000000Z],
          updated_at: ~U[2026-06-25 20:00:00.000000Z]
        ]
      )

      assert {:ok,
              %{
                status: :enqueued,
                boundary_at: boundary_at,
                timezone: "Asia/Shanghai",
                due_sessions: 1,
                actor_events: [reset_event]
              }} =
               ActorRuntime.enqueue_daily_session_resets(now: ~U[2026-06-25 20:30:30.000000Z])

      assert DateTime.compare(boundary_at, ~U[2026-06-25 20:30:00Z]) == :eq
      assert reset_event.type == "session.reset_due"
      assert reset_event.session_id == session_id
      assert reset_event.payload["data"]["reset"]["timezone"] == "Asia/Shanghai"
      assert reset_event.payload["data"]["reset"]["local_time"] == "04:30"
      assert reset_event.payload["data"]["reset"]["boundary_at"] == "2026-06-25T20:30:00Z"

      assert {:ok, %{actor_events: [same_reset_event]}} =
               ActorRuntime.enqueue_daily_session_resets(now: ~U[2026-06-25 20:31:00.000000Z])

      assert same_reset_event.id == reset_event.id

      assert Repo.aggregate(
               from(input in ActorEvent, where: input.type == "session.reset_due"),
               :count
             ) == 1
    end

    test "daily reset never enumerates subagent execution sessions" do
      %{principal: agent} = agent_fixture()

      assert {:ok, conversation} =
               Ankole.AIGateway.Conversations.ensure_conversation(
                 agent.uid,
                 "subagent:#{Ecto.UUID.generate()}"
               )

      Repo.update_all(
        from(stored in Conversation, where: stored.id == ^conversation.id),
        set: [
          inserted_at: ~U[2026-06-25 20:00:00.000000Z],
          updated_at: ~U[2026-06-25 20:00:00.000000Z]
        ]
      )

      assert {:ok, %{due_sessions: 0, actor_events: []}} =
               ActorRuntime.enqueue_daily_session_resets(now: ~U[2026-06-25 20:30:30.000000Z])
    end

    test "EnqueueDailySessionResets Oban job appends due reset actor events" do
      %{principal: agent} = agent_fixture()
      session_id = "manual-session:daily-reset-job"

      assert {:ok, "Asia/Shanghai"} = SystemConfig.put_timezone("Asia/Shanghai")

      assert {:ok, conversation} =
               Ankole.AIGateway.Conversations.ensure_conversation(agent.uid, session_id)

      Repo.update_all(
        from(stored in Conversation, where: stored.id == ^conversation.id),
        set: [
          inserted_at: ~U[2026-06-25 20:00:00.000000Z],
          updated_at: ~U[2026-06-25 20:00:00.000000Z]
        ]
      )

      assert :ok =
               perform_job(Ankole.SignalsGateway.ActorRuntime.Jobs.EnqueueDailySessionResets, %{})

      assert [
               %ActorEvent{
                 type: "session.reset_due",
                 session_id: ^session_id,
                 payload: payload
               }
             ] = Repo.all(from(event in ActorEvent, where: event.type == "session.reset_due"))

      assert payload["data"]["reset"]["timezone"] == "Asia/Shanghai"
      assert payload["data"]["reset"]["local_time"] == "04:30"
    end

    test "daily reset enqueuer records the configured reset time in the event payload" do
      %{principal: agent} = agent_fixture()
      session_id = "manual-session:daily-reset-custom-time"

      assert {:ok, "Asia/Shanghai"} = SystemConfig.put_timezone("Asia/Shanghai")

      assert {:ok, conversation} =
               Ankole.AIGateway.Conversations.ensure_conversation(agent.uid, session_id)

      Repo.update_all(
        from(stored in Conversation, where: stored.id == ^conversation.id),
        set: [
          inserted_at: ~U[2026-06-25 15:00:00.000000Z],
          updated_at: ~U[2026-06-25 15:00:00.000000Z]
        ]
      )

      assert {:ok,
              %{
                status: :enqueued,
                boundary_at: boundary_at,
                timezone: "Asia/Shanghai",
                actor_events: [reset_event]
              }} =
               ActorRuntime.enqueue_daily_session_resets(
                 now: ~U[2026-06-25 16:01:00.000000Z],
                 reset_time: ~T[00:00:00]
               )

      assert DateTime.compare(boundary_at, ~U[2026-06-25 16:00:00Z]) == :eq
      assert reset_event.payload["data"]["reset"]["timezone"] == "Asia/Shanghai"
      assert reset_event.payload["data"]["reset"]["local_time"] == "00:00"
      assert reset_event.payload["data"]["reset"]["boundary_at"] == "2026-06-25T16:00:00Z"
    end

    test "session reset_due waits for running work and preserves queued cron work" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_event: first_input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   source_event_id: "evt-reset-before",
                   signal_channel_id: "lark:chat:reset-barrier",
                   source_entry_id: "msg-reset-before",
                   provider_thread_id: "thread-reset-barrier",
                   text: "finish this first",
                   explicit: true
                 }),
                 now: @base_time
               )

      assert {:ok, %{conversation: first_conversation}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, first_envelope}
      first_start = first_envelope["body"]["turn_start"]
      first_turn_ref = first_start["turn"]

      assert first_start["actor_event"]["actor_event_id"] == first_input.id

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => first_turn_ref
                 }
               })

      session_id = first_input.session_id

      assert {:ok, reset_event} =
               append_runtime_actor_event(agent.uid, session_id, "session.reset_due",
                 now: DateTime.add(@base_time, 2, :second)
               )

      first_cron_slot = DateTime.add(@base_time, 2, :second)

      assert {:ok, %{cron_schedule: cron_schedule}} =
               Schedule.create_cron_schedule(
                 %{
                   "agent_uid" => agent.uid,
                   "session_id" => session_id,
                   "binding_name" => "bot",
                   "name" => "reset-boundary-cron",
                   "schedule" => %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "timezone" => "Etc/UTC",
                     "anchor_at" => DateTime.to_iso8601(first_cron_slot)
                   },
                   "payload" => %{"task" => "continue after reset"},
                   "delivery" => %{
                     "signal_channel_id" => "lark:chat:reset-barrier",
                     "provider_thread_id" => "thread-reset-barrier"
                   },
                   "idempotency_key" => "reset-boundary-cron",
                   "failure_policy" => %{}
                 },
                 now: DateTime.add(@base_time, 1, :second)
               )

      [scheduled_cron_event] = Schedule.list_cron_runs(cron_schedule.id, 10)

      assert {:ok, %{actor_event: deferred_cron_input}} =
               Schedule.fire_due_event(scheduled_cron_event.id, now: first_cron_slot)

      assert {:ok, %{actor_event: later_input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   source_event_id: "evt-reset-after",
                   signal_channel_id: "lark:chat:reset-barrier",
                   source_entry_id: "msg-reset-after",
                   provider_thread_id: "thread-reset-barrier",
                   text: "new day work",
                   explicit: true,
                   provider_time: DateTime.add(@base_time, 2, :second)
                 }),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, %{status: :waiting_for_generation, reason: :session_reset_due}} =
               process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

      assert Repo.get!(ActorEvent, reset_event.id).input_state == "open"
      assert Repo.get!(ActorEvent, deferred_cron_input.id).input_state == "open"
      assert Repo.get!(ActorEvent, later_input.id).input_state == "open"

      complete_aigateway_turn!(first_turn_ref, "done", wait_for_mirror: true)

      assert {:ok,
              %{
                status: :session_reset,
                closed_conversation: closed_conversation,
                conversation: next_conversation
              }} =
               process_ready_events_once(now: DateTime.add(@base_time, 4, :second))

      assert closed_conversation.id == first_conversation.id
      assert next_conversation.id != closed_conversation.id
      assert Repo.get!(Conversation, first_conversation.id).ended_at
      assert Repo.get(ActorEvent, reset_event.id)
      assert Repo.get!(ActorEvent, deferred_cron_input.id).input_state == "open"
      assert Repo.get!(ActorEvent, later_input.id).input_state == "open"

      assert {:ok,
              %{
                actor_event: ^deferred_cron_input,
                conversation: cron_conversation,
                send_outcome: "sent_or_queued"
              }} =
               process_ready_events_once(now: DateTime.add(@base_time, 5, :second))

      assert cron_conversation.id == next_conversation.id
      assert_receive {:actor_lane, cron_envelope}
      cron_start = cron_envelope["body"]["turn_start"]
      cron_turn_ref = cron_start["turn"]
      assert cron_start["actor_event"]["actor_event_id"] == deferred_cron_input.id
      assert cron_start["request_context"]["turn_mode"] == "cron"

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{"turn" => cron_turn_ref}
               })

      committed = complete_aigateway_turn!(cron_turn_ref, "scheduled work completed")

      assert {:ok, %{status: :turn_completed}} =
               ActorRuntime.handle_turn_completed(%{
                 "turn_completed" => %{
                   "turn" => cron_turn_ref,
                   "final_response_id" => "resp_#{committed.id}",
                   "outcome" => "loop_finished"
                 }
               })

      assert %DateTime{} = Repo.get!(ActorEvent, deferred_cron_input.id).completed_at

      assert {:ok, %{conversation: later_conversation}} =
               process_ready_events_once(now: DateTime.add(@base_time, 6, :second))

      assert later_conversation.id == next_conversation.id
      assert_receive {:actor_lane, later_envelope}
      later_start = later_envelope["body"]["turn_start"]
      assert later_start["actor_event"]["actor_event_id"] == later_input.id
    end
  end
end
