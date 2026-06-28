defmodule Ankole.ActorRuntime.WatchdogReconcilerTest do
  use Ankole.ActorRuntimeCase

  describe "watchdog and startup reconciler" do
    test "watchdog supersedes stale unaccepted delivery and retries through another worker" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      stale_route = unique_route()
      live_route = unique_route()

      :ok = Broker.register_local_worker(stale_route, self())
      on_exit(fn -> Broker.unregister_local_worker(stale_route) end)

      assert {:ok, stale_worker} = admit_worker(stale_route)

      Repo.update_all(
        from(worker in AgentComputerWorker, where: worker.worker_id == ^stale_worker.worker_id),
        set: [last_worker_heartbeat_at: @base_time]
      )

      assert {:ok, %{actor_input: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{llm_turn: first_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: 300
               )

      assert_receive {:actor_lane, _first_envelope}
      assert %ActorInputDelivery{state: "sent"} = wait_for_delivery_state(input.id, "sent")

      assert {:ok, %{stale_workers: 1}} =
               ActorRuntime.watchdog_once(
                 now: DateTime.add(@base_time, 120, :second),
                 stale_after_seconds: 60
               )

      assert Repo.get!(ActorInput, input.id).input_state == "open"

      assert %ActorInputDelivery{state: "superseded"} =
               Repo.one!(
                 from(delivery in ActorInputDelivery,
                   where: delivery.actor_input_id == ^input.id
                 )
               )

      :ok = Broker.register_local_worker(live_route, self())
      on_exit(fn -> Broker.unregister_local_worker(live_route) end)
      assert {:ok, live_worker} = admit_worker(live_route)

      assert {:ok, %{llm_turn: second_turn}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 121, :second))

      assert second_turn.id != first_turn.id
      assert Repo.get!(LlmTurn, first_turn.id).status == "failed"
      assert Repo.get!(LlmTurn, second_turn.id).kind == "retry_generation"

      assert_receive {:actor_lane, second_envelope}
      assert second_envelope["body"]["turn_start"]["turn"]["llm_turn_id"] == second_turn.id

      assert %ActorSessionActivation{
               assigned_worker_id: assigned_worker_id,
               current_llm_turn_id: current_llm_turn_id
             } =
               Repo.one!(from(activation in ActorSessionActivation))

      assert assigned_worker_id == live_worker.worker_id
      assert current_llm_turn_id == second_turn.id

      assert ["sent"] =
               ActorInputDelivery
               |> where([delivery], delivery.actor_input_id == ^input.id)
               |> order_by([delivery], asc: delivery.attempt_no)
               |> select([delivery], delivery.state)
               |> Repo.all()
    end

    test "watchdog deletes stale worker projections after the v1 ttl" do
      route = unique_route()
      assert {:ok, worker} = admit_worker(route)

      Repo.update_all(
        from(stored_worker in AgentComputerWorker, where: stored_worker.id == ^worker.id),
        set: [last_worker_heartbeat_at: @base_time]
      )

      assert {:ok, %{stale_workers: 1, deleted_stale_workers: 0}} =
               ActorRuntime.watchdog_once(
                 now: DateTime.add(@base_time, 120, :second),
                 stale_after_seconds: 60,
                 stale_worker_ttl_seconds: 3_600
               )

      assert %AgentComputerWorker{status: "stale"} = Repo.get!(AgentComputerWorker, worker.id)

      assert {:ok, %{stale_workers: 0, deleted_stale_workers: 1}} =
               ActorRuntime.watchdog_once(
                 now: DateTime.add(@base_time, 3_700, :second),
                 stale_after_seconds: 60,
                 stale_worker_ttl_seconds: 3_600
               )

      refute Repo.get(AgentComputerWorker, worker.id)
    end

    test "projection loss reconciles old started turn and creates retry generation" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{llm_turn: first_turn}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 1, :second))

      assert_receive {:actor_lane, first_envelope}
      first_turn_ref = first_envelope["body"]["turn_start"]["turn"]

      Repo.delete_all(ActorInputDelivery)
      Repo.delete_all(ActorSessionActivation)

      assert {:ok, 1} =
               ActorRuntime.reconcile_projection_lost_started_turns(
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert Repo.get!(LlmTurn, first_turn.id).status == "failed"
      assert Repo.get!(ActorInput, input.id).input_state == "open"

      assert {:error, :llm_turn_not_started} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => first_turn_ref,
                   "messages" => [],
                   "reply" => %{"text" => "PONG"}
                 }
               })

      assert {:ok, %{llm_turn: second_turn}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 3, :second))

      assert second_turn.id != first_turn.id
      assert Repo.get!(LlmTurn, second_turn.id).kind == "retry_generation"
      assert_receive {:actor_lane, second_envelope}
      assert second_envelope["body"]["turn_start"]["turn"]["llm_turn_id"] == second_turn.id
    end

    test "reconciler runs a startup projection-loss pass" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{llm_turn: started_turn}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 1, :second))

      assert_receive {:actor_lane, _envelope}

      Repo.delete_all(ActorInputDelivery)
      Repo.delete_all(ActorSessionActivation)

      start_supervised!({Reconciler, name: unique_process_name("reconciler")})

      assert %LlmTurn{status: "failed"} = wait_for_turn_status(started_turn.id, "failed")
      assert Repo.get!(ActorInput, input.id).input_state == "open"
    end
  end
end
