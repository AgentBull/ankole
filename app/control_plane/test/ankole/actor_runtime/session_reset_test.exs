defmodule Ankole.ActorRuntime.SessionResetTest do
  use Ankole.ActorRuntimeCase

  describe "session reset inputs" do
    test "daily reset enqueuer uses AppConfigure timezone and the 04:30 boundary" do
      %{principal: agent} = agent_fixture()
      session_id = "manual-session:daily-reset"

      assert {:ok, "Asia/Shanghai"} = SystemConfig.put_timezone("Asia/Shanghai")
      assert {:ok, conversation} = ActorRuntime.ensure_conversation(agent.uid, session_id)

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
                actor_inputs: [reset_input]
              }} =
               ActorRuntime.enqueue_daily_session_resets(now: ~U[2026-06-25 20:30:30.000000Z])

      assert DateTime.compare(boundary_at, ~U[2026-06-25 20:30:00Z]) == :eq
      assert reset_input.type == "session.reset_due"
      assert reset_input.session_id == session_id
      assert reset_input.payload["data"]["reset"]["timezone"] == "Asia/Shanghai"
      assert reset_input.payload["data"]["reset"]["local_time"] == "04:30"
      assert reset_input.payload["data"]["reset"]["boundary_at"] == "2026-06-25T20:30:00Z"

      assert {:ok, %{actor_inputs: [same_reset_input]}} =
               ActorRuntime.enqueue_daily_session_resets(now: ~U[2026-06-25 20:31:00.000000Z])

      assert same_reset_input.id == reset_input.id

      assert Repo.aggregate(
               from(input in ActorInput, where: input.type == "session.reset_due"),
               :count
             ) == 1
    end

    test "session reset_due waits for running work then rolls current session" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: first_input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   ingress_event_id: "evt-reset-before",
                   signal_channel_id: "lark:chat:reset-barrier",
                   provider_entry_id: "msg-reset-before",
                   provider_thread_id: "thread-reset-barrier",
                   text: "finish this first",
                   explicit: true
                 }),
                 now: @base_time
               )

      assert {:ok, %{llm_turn: first_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, first_envelope}
      first_start = first_envelope["body"]["turn_start"]
      first_turn_ref = first_start["turn"]
      first_input_ids = Enum.map(first_start["inputs"], & &1["actor_input_id"])

      assert first_input_ids == [first_input.id]

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => first_turn_ref,
                   "accepted_actor_input_ids" => first_input_ids
                 }
               })

      session_id = first_input.session_id

      assert {:ok, reset_input} =
               append_runtime_actor_input(agent.uid, session_id, "session.reset_due",
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, stale_timer_input} =
               append_runtime_actor_input(agent.uid, session_id, "timer.fired",
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, %{actor_input: later_input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   ingress_event_id: "evt-reset-after",
                   signal_channel_id: "lark:chat:reset-barrier",
                   provider_entry_id: "msg-reset-after",
                   provider_thread_id: "thread-reset-barrier",
                   text: "new day work",
                   explicit: true,
                   provider_time: DateTime.add(@base_time, 2, :second)
                 }),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, %{status: :waiting_for_generation, reason: :session_reset_due}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 3, :second))

      assert Repo.get!(ActorInput, reset_input.id).input_state == "open"
      assert Repo.get!(ActorInput, stale_timer_input.id).input_state == "open"
      assert Repo.get!(ActorInput, later_input.id).input_state == "open"

      assert {:ok, %{status: :committed}} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => first_turn_ref,
                   "messages" => [],
                   "reply" => %{"text" => "done"}
                 }
               })

      assert {:ok,
              %{
                status: :session_reset,
                closed_conversation: closed_conversation,
                conversation: next_conversation,
                stale_system_inputs: [discarded_input]
              }} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 4, :second))

      assert closed_conversation.id == first_turn.conversation_id
      assert next_conversation.id != closed_conversation.id
      assert discarded_input.id == stale_timer_input.id
      assert Repo.get!(Conversation, first_turn.conversation_id).ended_at
      refute Repo.get(ActorInput, reset_input.id)
      refute Repo.get(ActorInput, stale_timer_input.id)
      assert Repo.get!(ActorInput, later_input.id).input_state == "open"

      assert {:ok, %{llm_turn: later_turn}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 5, :second))

      assert later_turn.conversation_id == next_conversation.id
      assert_receive {:actor_lane, later_envelope}
      later_start = later_envelope["body"]["turn_start"]
      assert Enum.map(later_start["inputs"], & &1["actor_input_id"]) == [later_input.id]
    end
  end
end
