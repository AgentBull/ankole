defmodule Ankole.ActorRuntimeTest do
  use Ankole.DataCase, async: false

  import Ecto.Query
  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.AIAgent.Schemas.Message
  alias Ankole.Actors.ActorInput
  alias Ankole.Actors.ActorInputConsumption
  alias Ankole.ActorRuntime
  alias Ankole.ActorRuntime.ActivationManager
  alias Ankole.ActorRuntime.Config
  alias Ankole.ActorRuntime.OutboxDispatcher
  alias Ankole.ActorRuntime.Reconciler
  alias Ankole.ActorRuntime.WorkerBootstrap
  alias Ankole.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.ActorRuntime.Schemas.ActorInputDelivery
  alias Ankole.ActorRuntime.Transport.Broker
  alias Ankole.AppConfigure.Cache, as: AppConfigureCache
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.OutboxEntry

  @base_time ~U[2026-06-24 08:00:00.000000Z]

  describe "PING/PONG actor runtime path" do
    test "supervised runtime owners automatically dispatch PING to a worker and send PONG outbox" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      test_pid = self()
      route = unique_route()

      start_supervised!({ActivationManager, interval_ms: 20, limit: 10})

      start_supervised!(
        {OutboxDispatcher,
         interval_ms: 20,
         adapter_resolver: fn _outbox ->
           %{
             capabilities: [:reply_entry],
             send: fn outbox ->
               send(test_pid, {:auto_pong_outbox_sent, outbox.payload})
               {:ok, %{provider_entry_id: "provider-auto-pong"}}
             end
           }
         end}
      )

      :ok = Broker.register_local_worker(route, self())

      on_exit(fn -> Broker.unregister_local_worker(route) end)

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: input}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert_receive {:actor_bus, envelope}, 2_000

      turn_start = envelope["body"]["turn_start"]
      turn_ref = turn_start["turn"]
      input_ids = Enum.map(turn_start["inputs"], & &1["actor_input_id"])

      assert %ActorInputDelivery{state: "sent"} = wait_for_delivery_state(input.id, "sent")

      assert {:ok, _deliveries} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => turn_ref,
                   "accepted_actor_input_ids" => input_ids
                 }
               })

      assert {:ok, _result} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => turn_ref,
                   "messages" => [],
                   "reply" => %{"text" => "PONG"}
                 }
               })

      assert_receive {:auto_pong_outbox_sent, %{"text" => "PONG"}}, 2_000

      refute Repo.get(ActorInput, input.id)
      assert Repo.aggregate(ActorInputConsumption, :count) == 1
      assert Repo.aggregate(ActorInputDelivery, :count) == 0
      assert Repo.one!(from(turn in LlmTurn, select: turn.status)) == "succeeded"

      assert Repo.one!(
               from(message in Message,
                 where: message.role == "assistant",
                 select: message.content
               )
             ) == [
               %{"type" => "text", "text" => "PONG"}
             ]

      assert Repo.one!(from(outbox in OutboxEntry, select: outbox.status)) == :succeeded
    end

    test "commits accepted PING input as assistant PONG and provider outbox" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: input}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: llm_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: 86_400
               )

      assert_receive {:actor_bus, envelope}

      turn_start = envelope["body"]["turn_start"]
      turn_ref = turn_start["turn"]
      input_ids = Enum.map(turn_start["inputs"], & &1["actor_input_id"])

      assert input_ids == [input.id]

      assert {:ok, [%ActorInputDelivery{state: "accepted"}]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => turn_ref,
                   "accepted_actor_input_ids" => input_ids
                 }
               })

      assert {:ok, %{status: :committed, assistant_message: assistant_message}} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => turn_ref,
                   "messages" => [],
                   "reply" => %{"text" => "PONG"}
                 }
               })

      refute Repo.get(ActorInput, input.id)
      assert Repo.aggregate(ActorInputConsumption, :count) == 1
      assert Repo.aggregate(ActorInputDelivery, :count) == 0

      assert Repo.get!(LlmTurn, llm_turn.id).status == "succeeded"

      assert %Message{content: [%{"text" => "PONG"}]} =
               Repo.get!(Message, assistant_message.id)

      outbox = Repo.one!(from(outbox in OutboxEntry))
      assert outbox.source_actor_input_id == input.id
      assert outbox.llm_turn_id == llm_turn.id
      assert outbox.assistant_message_id == assistant_message.id
      assert outbox.operation == :reply
      assert outbox.payload == %{"text" => "PONG"}
      assert outbox.status == :created

      assert {:ok, sent_outbox} =
               SignalsGateway.dispatch_outbox(
                 agent.uid,
                 "bot",
                 outbox.outbound_key,
                 %{
                   capabilities: [:reply_entry],
                   send: fn outbox ->
                     send(self(), {:pong_outbox_sent, outbox.payload})
                     {:ok, %{provider_entry_id: "provider-pong-1"}}
                   end
                 }
               )

      assert_receive {:pong_outbox_sent, %{"text" => "PONG"}}
      assert sent_outbox.status == :succeeded
      assert sent_outbox.provider_entry_id == "provider-pong-1"
    end

    test "record_only input does not start an actor turn or emit PONG" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :record_only)
      route = unique_route()

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{status: :recorded}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: false}),
                 now: @base_time
               )

      assert {:ok, %{status: :idle}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 1, :second))

      assert Repo.aggregate(ActorInput, :count) == 0
      assert Repo.aggregate(LlmTurn, :count) == 0
      assert Repo.aggregate(OutboxEntry, :count) == 0
    end

    test "future available_at actor input is not delivered before ready time" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: input}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert DateTime.compare(input.available_at, @base_time) == :gt

      assert {:ok, %{status: :idle}} = ActorRuntime.process_ready_inputs_once(now: @base_time)
      assert Repo.aggregate(ActorInputDelivery, :count) == 0
      assert Repo.aggregate(LlmTurn, :count) == 0
      assert Repo.get!(ActorInput, input.id).input_state == "open"
    end

    test "no worker available leaves ready input open without creating generation artifacts" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{actor_input: input}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert {:error, :no_worker_available} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 1, :second))

      assert Repo.get!(ActorInput, input.id).input_state == "open"
      assert Repo.aggregate(Message, :count) == 0
      assert Repo.aggregate(LlmTurn, :count) == 0
      assert Repo.aggregate(ActorInputDelivery, :count) == 0
      assert Repo.aggregate(OutboxEntry, :count) == 0
    end

    test "route failure records send_failed delivery and leaves actor input open" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: input}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{send_outcome: "unknown_route"}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 1, :second))

      assert Repo.get!(ActorInput, input.id).input_state == "open"

      assert %ActorInputDelivery{state: "send_failed", send_outcome: "unknown_route"} =
               Repo.one!(from(delivery in ActorInputDelivery))

      assert Repo.aggregate(ActorInputConsumption, :count) == 0
      assert Repo.aggregate(OutboxEntry, :count) == 0
    end

    test "route retry reuses the materialized user message and started llm turn" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      dead_route = unique_route()
      live_route = unique_route()

      assert {:ok, _worker} = admit_worker(dead_route)

      assert {:ok, %{actor_input: input}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{send_outcome: "unknown_route", llm_turn: first_turn}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 1, :second))

      assert Repo.get!(ActorInput, input.id).input_state == "open"

      assert Repo.one!(
               from(message in Message, where: message.role == "user", select: count(message.id))
             ) == 1

      assert Repo.get!(LlmTurn, first_turn.id).status == "started"

      :ok = Broker.register_local_worker(live_route, self())
      on_exit(fn -> Broker.unregister_local_worker(live_route) end)
      assert {:ok, _worker} = admit_worker(live_route)

      assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: second_turn}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 2, :second))

      assert second_turn.id == first_turn.id

      assert Repo.one!(
               from(message in Message, where: message.role == "user", select: count(message.id))
             ) == 1

      assert_receive {:actor_bus, envelope}
      assert envelope["body"]["turn_start"]["turn"]["llm_turn_id"] == first_turn.id

      deliveries =
        Repo.all(from(delivery in ActorInputDelivery, order_by: [asc: delivery.attempt_no]))

      assert Enum.map(deliveries, & &1.state) == ["sent"]
      assert Enum.map(deliveries, & &1.attempt_no) == [2]
    end

    test "expired activation lease is failed before retrying a ready input" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      dead_route = unique_route()
      live_route = unique_route()

      assert {:ok, _worker} = admit_worker(dead_route)

      assert {:ok, %{actor_input: input}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{send_outcome: "unknown_route", llm_turn: first_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: 1
               )

      assert Repo.get!(ActorInput, input.id).input_state == "open"
      assert Repo.get!(LlmTurn, first_turn.id).status == "started"

      :ok = Broker.register_local_worker(live_route, self())
      on_exit(fn -> Broker.unregister_local_worker(live_route) end)
      assert {:ok, _worker} = admit_worker(live_route)

      assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: second_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(@base_time, 3, :second),
                 lease_seconds: 86_400
               )

      assert second_turn.id != first_turn.id
      assert Repo.get!(LlmTurn, first_turn.id).status == "failed"
      assert Repo.get!(LlmTurn, second_turn.id).kind == "retry_generation"

      activations =
        ActorSessionActivation
        |> order_by([activation], asc: activation.actor_epoch)
        |> Repo.all()

      assert Enum.map(activations, & &1.status) == ["failed", "active"]
      assert Enum.map(activations, & &1.actor_epoch) == [1, 2]

      assert_receive {:actor_bus, envelope}
      assert envelope["body"]["turn_start"]["turn"]["llm_turn_id"] == second_turn.id

      assert ["sent"] =
               ActorInputDelivery
               |> where([delivery], delivery.actor_input_id == ^input.id)
               |> order_by([delivery], asc: delivery.attempt_no)
               |> select([delivery], delivery.state)
               |> Repo.all()
    end

    test "worker capacity is used when assigning actor sessions" do
      %{principal: agent} = agent_fixture()
      full_route = unique_route()
      ready_route = unique_route()

      assert {:ok, _worker} =
               admit_worker(full_route, %{
                 capacity: %{"available_turn_slots" => 0},
                 load: %{"active_turns" => 1}
               })

      assert {:ok, ready_worker} =
               admit_worker(ready_route, %{
                 capacity: %{"available_turn_slots" => 1},
                 load: %{"active_turns" => 0}
               })

      assert {:ok, assignment} =
               ActorRuntime.assign_worker(%{
                 agent_uid: agent.uid,
                 session_id: "signal-channel:capacity"
               })

      assert assignment.worker_id == ready_worker.worker_id
      assert assignment.worker_instance_id == ready_worker.worker_instance_id
      assert assignment.transport_route == ready_route
    end

    test "turn_error fails the current turn and keeps the input open for a new activation" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: input}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{llm_turn: first_turn}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 1, :second))

      assert_receive {:actor_bus, first_envelope}
      assert %ActorInputDelivery{state: "sent"} = wait_for_delivery_state(input.id, "sent")

      first_turn_ref = first_envelope["body"]["turn_start"]["turn"]

      assert {:ok, %{status: :turn_failed}} =
               ActorRuntime.handle_turn_error(%{
                 "turn_error" => %{
                   "turn" => first_turn_ref,
                   "code" => "worker_loop_failed",
                   "message" => "placeholder failed",
                   "details_json" => %{"retryable" => true}
                 }
               })

      assert Repo.get!(LlmTurn, first_turn.id).status == "failed"
      assert Repo.get!(ActorInput, input.id).input_state == "open"

      assert Repo.one!(from(delivery in ActorInputDelivery, select: delivery.state)) ==
               "superseded"

      assert Repo.aggregate(ActorInputConsumption, :count) == 0
      assert Repo.aggregate(OutboxEntry, :count) == 0

      assert {:ok, %{llm_turn: second_turn}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 2, :second))

      assert second_turn.id != first_turn.id
      assert Repo.get!(LlmTurn, second_turn.id).kind == "retry_generation"

      assert Repo.one!(
               from(message in Message, where: message.role == "user", select: count(message.id))
             ) == 1

      assert_receive {:actor_bus, second_envelope}
      assert second_envelope["body"]["turn_start"]["turn"]["actor_epoch"] == 2
    end

    test "expired activation rejects late final proposal without provider output" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: input}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{llm_turn: llm_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: 86_400
               )

      assert_receive {:actor_bus, envelope}
      turn_start = envelope["body"]["turn_start"]
      turn_ref = turn_start["turn"]
      input_ids = Enum.map(turn_start["inputs"], & &1["actor_input_id"])

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => turn_ref,
                   "accepted_actor_input_ids" => input_ids
                 }
               })

      Repo.update_all(
        from(activation in ActorSessionActivation,
          where: activation.activation_uid == ^turn_ref["activation_uid"]
        ),
        set: [lease_expires_at: DateTime.add(DateTime.utc_now(:microsecond), -1, :second)]
      )

      assert {:error, :activation_lease_expired} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => turn_ref,
                   "messages" => [],
                   "reply" => %{"text" => "PONG"}
                 }
               })

      assert Repo.get!(LlmTurn, llm_turn.id).status == "started"
      assert Repo.get!(ActorInput, input.id).input_state == "open"

      assert Repo.aggregate(from(message in Message, where: message.role == "assistant"), :count) ==
               0

      assert Repo.aggregate(ActorInputConsumption, :count) == 0
      assert Repo.aggregate(OutboxEntry, :count) == 0
    end

    test "recalled input rejects late final proposal without provider output" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: input}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{llm_turn: llm_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: 86_400
               )

      assert_receive {:actor_bus, envelope}
      turn_start = envelope["body"]["turn_start"]
      turn_ref = turn_start["turn"]
      input_ids = Enum.map(turn_start["inputs"], & &1["actor_input_id"])

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => turn_ref,
                   "accepted_actor_input_ids" => input_ids
                 }
               })

      assert {:ok, %{canceled_actor_inputs: 1, lifecycle_inputs: []}} =
               SignalsGateway.emit_entry_recalled(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{
                   ingress_event_id: "recall-before-final",
                   signal_channel_id: input.signal_channel_id,
                   provider_entry_id: input.provider_entry_id,
                   provider_thread_id: input.provider_thread_id
                 }),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:error, :no_accepted_delivery} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => turn_ref,
                   "messages" => [],
                   "reply" => %{"text" => "PONG"}
                 }
               })

      assert Repo.get!(LlmTurn, llm_turn.id).status == "started"
      refute Repo.get(ActorInput, input.id)

      assert Repo.aggregate(from(message in Message, where: message.role == "assistant"), :count) ==
               0

      assert Repo.aggregate(ActorInputConsumption, :count) == 0
      assert Repo.aggregate(OutboxEntry, :count) == 0
    end

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
               SignalsGateway.emit_entry(
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

      assert_receive {:actor_bus, _first_envelope}
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

      assert_receive {:actor_bus, second_envelope}
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
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{llm_turn: first_turn}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 1, :second))

      assert_receive {:actor_bus, first_envelope}
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
      assert_receive {:actor_bus, second_envelope}
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
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{llm_turn: started_turn}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 1, :second))

      assert_receive {:actor_bus, _envelope}

      Repo.delete_all(ActorInputDelivery)
      Repo.delete_all(ActorSessionActivation)

      start_supervised!({Reconciler, name: unique_process_name("reconciler")})

      assert %LlmTurn{status: "failed"} = wait_for_turn_status(started_turn.id, "failed")
      assert Repo.get!(ActorInput, input.id).input_state == "open"
    end

    test "channel reply mode uses post outbox operation when entry reply is unavailable" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: input}} =
               SignalsGateway.emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   text: "PING",
                   explicit: true,
                   channel: %{kind: :im_group, reply_mode: :channel, name: "Ops"}
                 }),
                 now: @base_time
               )

      assert {:ok, %{llm_turn: llm_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: 86_400
               )

      assert_receive {:actor_bus, envelope}
      assert %ActorInputDelivery{state: "sent"} = wait_for_delivery_state(input.id, "sent")
      turn_start = envelope["body"]["turn_start"]
      turn_ref = turn_start["turn"]
      input_ids = Enum.map(turn_start["inputs"], & &1["actor_input_id"])

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
                   "reply" => %{"text" => "PONG"}
                 }
               })

      llm_turn_id = llm_turn.id

      assert %OutboxEntry{operation: :post, llm_turn_id: ^llm_turn_id} =
               Repo.one!(from(outbox in OutboxEntry))
    end

    test "broker uses ZeroMQ mandatory route outcome when router is running" do
      assert {:ok, endpoint} =
               Broker.start_router("tcp://127.0.0.1:*",
                 pre_auth_token: "test-token",
                 poll_interval_ms: 1
               )

      on_exit(fn -> Broker.stop_router() end)

      assert endpoint =~ "tcp://"

      assert {:error, :unknown_route} =
               Broker.send_mandatory("missing-worker", worker_ready_envelope())
    end

    test "worker heartbeat and capacity update only the authenticated worker projection" do
      route = unique_route()
      assert {:ok, worker} = admit_worker(route)

      assert {:ok, heartbeat_worker} =
               ActorRuntime.handle_worker_heartbeat(
                 %{
                   "worker_id" => worker.worker_id,
                   "worker_instance_id" => worker.worker_instance_id,
                   "monotonic_ms" => 123,
                   "load_json" => %{"active_turns" => 1}
                 },
                 %{authenticated?: true, transport_route: route}
               )

      assert heartbeat_worker.load == %{"active_turns" => 1}

      assert {:ok, capacity_worker} =
               ActorRuntime.handle_worker_capacity(
                 %{
                   "worker_id" => worker.worker_id,
                   "worker_instance_id" => worker.worker_instance_id,
                   "available_turn_slots" => 2,
                   "capacity_json" => %{"available_turn_slots" => 2},
                   "load_json" => %{"active_turns" => 0}
                 },
                 %{authenticated?: true, transport_route: route}
               )

      assert capacity_worker.capacity == %{"available_turn_slots" => 2}
      assert capacity_worker.load == %{"active_turns" => 0}

      assert {:error, :stale_transport_route} =
               ActorRuntime.handle_worker_heartbeat(
                 %{
                   "worker_id" => worker.worker_id,
                   "worker_instance_id" => worker.worker_instance_id
                 },
                 %{authenticated?: true, transport_route: route <> "-stale"}
               )
    end

    test "worker admission rejects duplicate live instance and route ownership" do
      route = unique_route()
      duplicate_route = unique_route()
      assert {:ok, worker} = admit_worker(route)

      assert {:error, :duplicate_worker_instance} =
               ActorRuntime.admit_worker_ready(
                 %{
                   worker_id: "other-worker-instance",
                   worker_instance_id: worker.worker_instance_id,
                   runtime: "bun",
                   version: "test",
                   capacity: %{"available_turn_slots" => 1}
                 },
                 %{authenticated?: true, transport_route: duplicate_route}
               )

      assert {:error, :duplicate_worker_route} =
               ActorRuntime.admit_worker_ready(
                 %{
                   worker_id: "other-worker-route",
                   worker_instance_id: "other-worker-route-instance",
                   runtime: "bun",
                   version: "test",
                   capacity: %{"available_turn_slots" => 1}
                 },
                 %{authenticated?: true, transport_route: route}
               )

      assert {:ok, refreshed_worker} =
               ActorRuntime.admit_worker_ready(
                 %{
                   worker_id: worker.worker_id,
                   worker_instance_id: "refreshed-" <> worker.worker_instance_id,
                   runtime: "bun",
                   version: "test",
                   capacity: %{"available_turn_slots" => 2}
                 },
                 %{authenticated?: true, transport_route: duplicate_route}
               )

      assert refreshed_worker.worker_id == worker.worker_id
      assert refreshed_worker.worker_instance_id == "refreshed-" <> worker.worker_instance_id
      assert refreshed_worker.transport_route == duplicate_route
    end

    test "worker admission requires runtime and version identity fields" do
      route = unique_route()

      assert {:error, {:missing, "runtime"}} =
               ActorRuntime.admit_worker_ready(
                 %{
                   worker_id: "worker-missing-runtime",
                   worker_instance_id: "worker-missing-runtime-instance",
                   version: "test",
                   capacity: %{"available_turn_slots" => 1}
                 },
                 %{authenticated?: true, transport_route: route}
               )

      assert {:error, {:missing, "version"}} =
               ActorRuntime.admit_worker_ready(
                 %{
                   worker_id: "worker-missing-version",
                   worker_instance_id: "worker-missing-version-instance",
                   runtime: "bun",
                   capacity: %{"available_turn_slots" => 1}
                 },
                 %{authenticated?: true, transport_route: route}
               )

      assert Repo.aggregate(AgentComputerWorker, :count) == 0
    end

    test "worker bootstrap renders an operator command without actor-specific args" do
      assert {:ok, command} =
               WorkerBootstrap.docker_run_command(
                 endpoint: "tcp://127.0.0.1:6010",
                 worker_id: "worker-a",
                 worker_instance_id: "worker-a-1"
               )

      assert command =~ "docker run --rm"
      assert command =~ "ANKOLE_ACTOR_BUS_ENDPOINT"
      assert command =~ "ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN"
      assert command =~ "ANKOLE_AGENT_COMPUTER_WORKER_ID"
      assert command =~ "ANKOLE_AGENT_COMPUTER_WORKER_INSTANCE_ID"
      assert command =~ "ANKOLE_WORKSPACE_ROOT=/workspace"
      assert command =~ "/workspace/user-files"
      assert command =~ "/workspace/temp"
      assert command =~ "/workspace/library-containers"
      refute command =~ "ANKOLE_AGENT_UID"
      refute command =~ "--agent-uid"
    end

    test "pre-auth token read does not generate and bootstrap explicitly persists it" do
      AppConfigureCache.clear_for_test()

      assert :error = Config.pre_auth_token()

      assert {:ok, command} =
               WorkerBootstrap.docker_run_command(
                 endpoint: "tcp://127.0.0.1:6010",
                 worker_id: "worker-token",
                 worker_instance_id: "worker-token-1"
               )

      assert {:ok, token} = Config.pre_auth_token()
      assert is_binary(token)
      assert token != ""
      assert command =~ "ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN='#{token}'"
    end
  end

  defp admit_worker(route, overrides \\ %{}) do
    ActorRuntime.admit_worker_ready(
      Map.merge(
        %{
          worker_id: "worker-" <> route,
          worker_instance_id: "instance-" <> route,
          runtime: "bun",
          version: "test",
          capacity: %{"available_turn_slots" => 4}
        },
        overrides
      ),
      %{authenticated?: true, transport_route: route}
    )
  end

  defp binding_fixture(agent_uid, name, policy) do
    {:ok, binding} =
      SignalsGateway.upsert_binding(%{
        agent_uid: agent_uid,
        name: name,
        adapter: "lark",
        config_ref: "app-config://#{name}",
        filters: %{},
        unaddressed_group_message_policy: policy
      })

    binding
  end

  defp group_entry(overrides) do
    Map.merge(
      %{
        ingress_event_id: "evt-" <> Integer.to_string(System.unique_integer([:positive])),
        signal_channel_id: "lark:chat:group-a",
        provider_entry_id: "msg-" <> Integer.to_string(System.unique_integer([:positive])),
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
        ingress_event_id: "lifecycle-" <> Integer.to_string(System.unique_integer([:positive])),
        signal_channel_id: "lark:chat:group-a",
        provider_entry_id: "msg-" <> Integer.to_string(System.unique_integer([:positive])),
        provider_thread_id: "thread-1",
        channel: %{kind: :im_group, reply_mode: :entry, name: "Ops"}
      },
      overrides
    )
  end

  defp unique_route do
    "local-test-route-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp unique_process_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp worker_ready_envelope do
    %{
      "protocol_version" => 1,
      "message_id" => "worker-ready-test",
      "lane" => "LANE_CONTROL",
      "durability" => "CONTROL_EPHEMERAL",
      "body" => %{
        "type" => "worker_ready",
        "worker_ready" => %{
          "worker_id" => "worker-a",
          "worker_instance_id" => "worker-a-1",
          "runtime" => "bun",
          "version" => "test"
        }
      }
    }
  end

  defp wait_for_delivery_state(actor_input_id, state, attempts \\ 100)

  defp wait_for_delivery_state(actor_input_id, state, attempts) when attempts > 0 do
    case Repo.get_by(ActorInputDelivery, actor_input_id: actor_input_id, state: state) do
      %ActorInputDelivery{} = delivery ->
        delivery

      nil ->
        Process.sleep(10)
        wait_for_delivery_state(actor_input_id, state, attempts - 1)
    end
  end

  defp wait_for_delivery_state(actor_input_id, state, 0) do
    flunk("delivery #{actor_input_id} did not reach #{state}")
  end

  defp wait_for_turn_status(llm_turn_id, status, attempts \\ 100)

  defp wait_for_turn_status(llm_turn_id, status, attempts) when attempts > 0 do
    case Repo.get!(LlmTurn, llm_turn_id) do
      %LlmTurn{status: ^status} = turn ->
        turn

      %LlmTurn{} ->
        Process.sleep(10)
        wait_for_turn_status(llm_turn_id, status, attempts - 1)
    end
  end

  defp wait_for_turn_status(llm_turn_id, status, 0) do
    flunk("llm turn #{llm_turn_id} did not reach #{status}")
  end
end
