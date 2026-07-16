defmodule Ankole.SignalsGateway.ActorRuntime.TransportTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  describe "transport, admission, and bootstrap" do
    test "broker uses ZeroMQ mandatory route outcome when router is running" do
      assert {:ok, endpoint} =
               Broker.start_router("tcp://127.0.0.1:*",
                 worker_auth_key: "test-token",
                 poll_interval_ms: 1
               )

      on_exit(fn -> Broker.stop_router() end)

      assert endpoint =~ "tcp://"

      assert {:error, :unknown_route} =
               Broker.send_mandatory("missing-worker", worker_ready_envelope())
    end

    test "broker retries a transient router bind conflict until transport recovers" do
      assert {:ok, occupied_router} =
               Ankole.Kernel.RuntimeFabric.router_start("tcp://127.0.0.1:*", self(),
                 worker_auth_key: "test-token",
                 poll_interval_ms: 1
               )

      on_exit(fn -> Ankole.Kernel.RuntimeFabric.router_stop(occupied_router) end)
      endpoint = Ankole.Kernel.RuntimeFabric.router_endpoint(occupied_router)
      broker_name = unique_process_name("retrying_runtime_fabric_broker")

      start_supervised!(
        {Broker,
         name: broker_name,
         router: [
           endpoint: endpoint,
           worker_auth_key: "test-token",
           poll_interval_ms: 1
         ]}
      )

      assert %{router: nil, router_retry_timer: timer} = :sys.get_state(broker_name)
      assert is_reference(timer)
      assert :ok = Ankole.Kernel.RuntimeFabric.router_stop(occupied_router)

      assert {:ok, ^endpoint} = wait_for_router_endpoint(broker_name, 200)
    end

    test "control plane can call a worker RPC method over the RPC lane" do
      route = unique_route()
      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)

      task =
        Task.async(fn ->
          Broker.request_rpc(
            route,
            "test.probe",
            %{"probe" => true},
            timeout_ms: 200
          )
        end)

      assert_receive {:actor_lane,
                      %{
                        "body" => %{
                          "type" => "rpc_request",
                          "rpc_request" => request
                        }
                      }},
                     200

      assert request["method"] == "test.probe"
      assert request["payload_json"] == %{"probe" => true}
      request_id = request["request_id"]

      send(
        Broker,
        {:runtime_fabric_router_received, route,
         Torque.encode!(%{
           "protocol_version" => 1,
           "message_id" => "worker-rpc-response",
           "correlation_id" => request_id,
           "lane" => "LANE_RPC",
           "durability" => "CONTROL_EPHEMERAL",
           "body" => %{
             "type" => "rpc_response",
             "rpc_response" => %{
               "request_id" => request_id,
               "payload_json" => %{"runtime" => "bun", "active_turns" => 0}
             }
           }
         })}
      )

      assert {:ok, %{"runtime" => "bun", "active_turns" => 0}} = Task.await(task, 500)
    end

    test "a crashing RPC handler returns rpc_error without terminating the transport broker" do
      %{principal: agent} = agent_fixture()
      config_owner = Ankole.SignalsGateway.ActorRuntime.AIGatewayAPIKeyBroker
      previous_config = Application.get_env(:ankole, config_owner)
      Application.put_env(:ankole, config_owner, worker_facing_base_url: :invalid_test_value)

      on_exit(fn ->
        case previous_config do
          nil -> Application.delete_env(:ankole, config_owner)
          value -> Application.put_env(:ankole, config_owner, value)
        end
      end)

      request = %{
        "request_id" => "rpc-handler-crash",
        "method" => "ai_gateway.api_key_for.create_or_find_by_agent",
        "payload_json" => %{"agent_uid" => agent.uid}
      }

      assert {:ok, response} = RPCLane.handle_request(request, "worker-route")
      assert get_in(response, ["body", "type"]) == "rpc_error"
      assert get_in(response, ["body", "rpc_error", "code"]) == "rpc_handler_failed"

      broker_pid = Process.whereis(Broker)

      send(
        Broker,
        {:runtime_fabric_router_received, "worker-route",
         Torque.encode!(%{
           "protocol_version" => 1,
           "message_id" => "rpc-handler-crash-envelope",
           "correlation_id" => "rpc-handler-crash",
           "lane" => "LANE_RPC",
           "durability" => "CONTROL_EPHEMERAL",
           "body" => %{"type" => "rpc_request", "rpc_request" => request}
         })}
      )

      :sys.get_state(Broker)
      assert Process.alive?(broker_pid)
    end

    test "ambient may_intervene turns use the light model profile" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :may_intervene)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_event: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "the strategy may need a backtest"}),
                 now: @base_time
               )

      assert input.type == "im.message.may_intervene"

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 20, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}
      assert get_in(envelope, ["body", "turn_start", "model_ref", "profile"]) == "light"
    end

    test "worker heartbeat and capacity update only the authenticated worker projection" do
      route = unique_route()
      assert {:ok, worker} = admit_worker(route)

      assert {:ok, heartbeat_worker} =
               ActorRuntime.handle_worker_heartbeat(
                 %{
                   "worker_id" => worker.worker_id,
                   "incarnation_id" => worker.incarnation_id,
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
                   "incarnation_id" => worker.incarnation_id,
                   "available_turn_slots" => 2,
                   "capacity_json" => %{"available_turn_slots" => 2},
                   "load_json" => %{"active_turns" => 0}
                 },
                 %{authenticated?: true, transport_route: route}
               )

      assert capacity_worker.capacity == %{"available_turn_slots" => 2}
      assert capacity_worker.load == %{"active_turns" => 0}

      assert {:error, :stale_worker_incarnation} =
               ActorRuntime.handle_worker_heartbeat(
                 %{
                   "worker_id" => worker.worker_id,
                   "incarnation_id" => "replaced-incarnation"
                 },
                 %{authenticated?: true, transport_route: route}
               )

      assert {:error, :stale_transport_route} =
               ActorRuntime.handle_worker_heartbeat(
                 %{
                   "worker_id" => worker.worker_id,
                   "incarnation_id" => worker.incarnation_id
                 },
                 %{authenticated?: true, transport_route: route <> "-stale"}
               )
    end

    test "authenticated heartbeat revalidates the same live worker after a stale transition" do
      route = unique_route()
      assert {:ok, worker} = admit_worker(route)

      assert {:ok, 1} =
               Ankole.SignalsGateway.ActorRuntime.WorkerAdmission.mark_all_routes_unusable(
                 :router_stopped
               )

      assert %AgentComputerWorker{status: "stale", stop_reason: "router_stopped"} =
               Repo.get!(AgentComputerWorker, worker.id)

      assert {:ok, revalidated} =
               ActorRuntime.handle_worker_heartbeat(
                 %{
                   "worker_id" => worker.worker_id,
                   "incarnation_id" => worker.incarnation_id,
                   "monotonic_ms" => 123,
                   "load_json" => %{"active_turns" => 0}
                 },
                 %{authenticated?: true, transport_route: route}
               )

      assert revalidated.status == "ready"
      assert is_nil(revalidated.stopped_at)
      assert is_nil(revalidated.stop_reason)

      stale_at = DateTime.add(revalidated.last_worker_heartbeat_at, 61, :second)

      assert {:ok, timed_out} =
               ActorRuntime.mark_worker_stale_if_due(revalidated.worker_id,
                 now: stale_at,
                 stale_after_seconds: 60
               )

      assert timed_out.status == "stale"
      assert timed_out.stop_reason == "heartbeat_timeout"

      assert {:ok, recovered} =
               ActorRuntime.handle_worker_heartbeat(
                 %{
                   "worker_id" => worker.worker_id,
                   "incarnation_id" => worker.incarnation_id
                 },
                 %{authenticated?: true, transport_route: route}
               )

      assert recovered.status == "ready"
      assert is_nil(recovered.stopped_at)
      assert is_nil(recovered.stop_reason)
    end

    test "broker rejects worker actor lane writes from an unassigned route" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()
      wrong_route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_event: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}

      turn_start = envelope["body"]["turn_start"]
      turn_ref = turn_start["turn"]

      assert %ActorEventDelivery{state: "sent"} = wait_for_delivery_state(input.id, "sent")
      assert {:ok, _wrong_worker} = admit_worker(wrong_route)

      accepted_envelope = %{
        "protocol_version" => 1,
        "message_id" => "turn-accepted-wrong-route",
        "correlation_id" => envelope["message_id"],
        "lane" => "LANE_TURN",
        "durability" => "CONTROL_REPLAYABLE",
        "body" => %{
          "type" => "turn_accepted",
          "turn_accepted" => %{
            "turn" => turn_ref
          }
        }
      }

      send(
        Broker,
        {:runtime_fabric_router_received, wrong_route, nil, nil,
         Torque.encode!(accepted_envelope)}
      )

      :sys.get_state(Broker)

      assert %ActorEventDelivery{state: "sent"} =
               Repo.get_by!(ActorEventDelivery, actor_event_id: input.id)

      send(
        Broker,
        {:runtime_fabric_router_received, route, nil, nil, Torque.encode!(accepted_envelope)}
      )

      :sys.get_state(Broker)

      assert %ActorEventDelivery{state: "accepted"} =
               Repo.get_by!(ActorEventDelivery, actor_event_id: input.id)
    end

    test "broker ignores obsolete worker final proposals" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_event: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "PING", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}
      turn_ref = envelope["body"]["turn_start"]["turn"]
      assert %ActorEventDelivery{state: "sent"} = wait_for_delivery_state(input.id, "sent")

      proposal_envelope = %{
        "protocol_version" => 1,
        "message_id" => "obsolete-turn-final-proposal",
        "correlation_id" => envelope["message_id"],
        "lane" => "LANE_TURN",
        "durability" => "CONTROL_DURABLE",
        "body" => %{
          "type" => "turn_final_proposal",
          "turn_final_proposal" => %{
            "turn" => turn_ref,
            "messages" => [],
            "reply" => %{"text" => "PONG"}
          }
        }
      }

      send(
        Broker,
        {:runtime_fabric_router_received, route, nil, nil, Torque.encode!(proposal_envelope)}
      )

      :sys.get_state(Broker)
      assert is_nil(Repo.get!(ActorEvent, input.id).completed_at)

      assert %ActorEventDelivery{state: "sent"} =
               Repo.get_by!(ActorEventDelivery, actor_event_id: input.id)

      refute Repo.exists?(from(outbox in OutboxEntry))

      refute Repo.exists?(
               from(message in Message,
                 where:
                   fragment("?#>>'{request_metadata,actor_event_id}'", message.metadata) ==
                     ^input.id
               )
             )
    end

    test "broker accepts terminal worker writes after active steer bumps revision" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_event: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "observe only", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}, 2_000
      turn_ref = envelope["body"]["turn_start"]["turn"]

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{"turn" => turn_ref}
               })

      assert {:ok, %{actor_event: steer_event}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "/steer stay quiet", explicit: true}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, %{status: :active_steer_nudged, send_outcome: "sent_or_queued"}} =
               process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

      assert_receive {:actor_lane, mailbox_envelope}, 2_000
      assert mailbox_envelope["body"]["type"] == "mailbox_updated"

      assert mailbox_envelope["body"]["mailbox_updated"]["actor_event"]["actor_event_id"] ==
               steer_event.id

      mailbox = mailbox_envelope["body"]["mailbox_updated"]

      assert {:ok, [%ActorEventDelivery{state: "accepted", actor_event_id: steer_id}]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{"turn" => mailbox["turn"]}
               })

      assert steer_id == steer_event.id

      noop_envelope = %{
        "protocol_version" => 1,
        "message_id" => "turn-noop-after-steer",
        "correlation_id" => envelope["message_id"],
        "lane" => "LANE_TURN",
        "durability" => "CONTROL_REPLAYABLE",
        "body" => %{
          "type" => "turn_noop_completed",
          "turn_noop_completed" => %{
            "turn" => turn_ref,
            "reason" => "ambient_silent"
          }
        }
      }

      send(
        Broker,
        {:runtime_fabric_router_received, route, nil, nil, Torque.encode!(noop_envelope)}
      )

      :sys.get_state(Broker)

      assert %DateTime{} = Repo.get!(ActorEvent, input.id).completed_at
      assert %DateTime{} = Repo.get!(ActorEvent, steer_event.id).completed_at
    end

    test "worker admission rejects duplicate live route ownership" do
      route = unique_route()
      duplicate_route = unique_route()
      assert {:ok, worker} = admit_worker(route)

      assert {:error, :duplicate_worker_route} =
               ActorRuntime.admit_worker_ready(
                 %{
                   worker_id: "other-worker-route",
                   incarnation_id: "incarnation-other-worker-route",
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
                   incarnation_id: worker.incarnation_id,
                   runtime: "bun",
                   version: "test",
                   capacity: %{"available_turn_slots" => 2}
                 },
                 %{authenticated?: true, transport_route: duplicate_route}
               )

      assert refreshed_worker.worker_id == worker.worker_id
      assert refreshed_worker.transport_route == duplicate_route
      assert refreshed_worker.capacity == %{"available_turn_slots" => 2}
    end

    test "worker admission requires runtime, version, and incarnation identity fields" do
      route = unique_route()

      assert {:error, {:missing, "runtime"}} =
               ActorRuntime.admit_worker_ready(
                 %{
                   worker_id: "worker-missing-runtime",
                   incarnation_id: "incarnation-missing-runtime",
                   version: "test",
                   capacity: %{"available_turn_slots" => 1}
                 },
                 %{authenticated?: true, transport_route: route}
               )

      assert {:error, {:missing, "version"}} =
               ActorRuntime.admit_worker_ready(
                 %{
                   worker_id: "worker-missing-version",
                   incarnation_id: "incarnation-missing-version",
                   runtime: "bun",
                   capacity: %{"available_turn_slots" => 1}
                 },
                 %{authenticated?: true, transport_route: route}
               )

      assert {:error, {:missing, "incarnation_id"}} =
               ActorRuntime.admit_worker_ready(
                 %{
                   worker_id: "worker-missing-incarnation",
                   runtime: "bun",
                   version: "test",
                   capacity: %{"available_turn_slots" => 1}
                 },
                 %{authenticated?: true, transport_route: route}
               )

      assert Repo.aggregate(AgentComputerWorker, :count) == 0
    end
  end

  defp wait_for_router_endpoint(broker, attempts) when attempts > 0 do
    case GenServer.call(broker, :router_endpoint) do
      {:ok, _endpoint} = ready ->
        ready

      {:error, :not_started} ->
        receive do
        after
          10 -> wait_for_router_endpoint(broker, attempts - 1)
        end
    end
  end

  defp wait_for_router_endpoint(_broker, 0), do: {:error, :router_not_recovered}
end
