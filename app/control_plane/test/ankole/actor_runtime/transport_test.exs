defmodule Ankole.ActorRuntime.TransportTest do
  use Ankole.ActorRuntimeCase

  describe "transport, admission, and bootstrap" do
    test "channel reply mode uses post outbox operation when entry reply is unavailable" do
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
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}
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
                 worker_auth_key: "test-token",
                 poll_interval_ms: 1
               )

      on_exit(fn -> Broker.stop_router() end)

      assert endpoint =~ "tcp://"

      assert {:error, :unknown_route} =
               Broker.send_mandatory("missing-worker", worker_ready_envelope())
    end

    test "control plane can call a worker RPC method over the RPC lane" do
      route = unique_route()
      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)

      task =
        Task.async(fn ->
          ActorRuntime.request_worker_rpc(
            route,
            "worker.runtime.describe",
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

      assert request["method"] == "worker.runtime.describe"
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

    test "worker heartbeat and capacity update only the authenticated worker projection" do
      route = unique_route()
      assert {:ok, worker} = admit_worker(route)

      assert {:ok, heartbeat_worker} =
               ActorRuntime.handle_worker_heartbeat(
                 %{
                   "worker_id" => worker.worker_id,
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
                   "worker_id" => worker.worker_id
                 },
                 %{authenticated?: true, transport_route: route <> "-stale"}
               )
    end

    test "broker rejects worker actor lane writes from an unassigned route" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()
      wrong_route = unique_route()

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

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}

      turn_start = envelope["body"]["turn_start"]
      turn_ref = turn_start["turn"]
      accepted_ids = Enum.map(turn_start["inputs"], & &1["actor_input_id"])

      assert %ActorInputDelivery{state: "sent"} = wait_for_delivery_state(input.id, "sent")
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
            "turn" => turn_ref,
            "accepted_actor_input_ids" => accepted_ids
          }
        }
      }

      send(
        Broker,
        {:runtime_fabric_router_received, wrong_route, nil, nil,
         Torque.encode!(accepted_envelope)}
      )

      :sys.get_state(Broker)

      assert %ActorInputDelivery{state: "sent"} =
               Repo.get_by!(ActorInputDelivery, actor_input_id: input.id)

      send(
        Broker,
        {:runtime_fabric_router_received, route, nil, nil, Torque.encode!(accepted_envelope)}
      )

      :sys.get_state(Broker)

      assert %ActorInputDelivery{state: "accepted"} =
               Repo.get_by!(ActorInputDelivery, actor_input_id: input.id)
    end

    test "worker admission rejects duplicate live route ownership" do
      route = unique_route()
      duplicate_route = unique_route()
      assert {:ok, worker} = admit_worker(route)

      assert {:error, :duplicate_worker_route} =
               ActorRuntime.admit_worker_ready(
                 %{
                   worker_id: "other-worker-route",
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

    test "worker admission requires runtime and version identity fields" do
      route = unique_route()

      assert {:error, {:missing, "runtime"}} =
               ActorRuntime.admit_worker_ready(
                 %{
                   worker_id: "worker-missing-runtime",
                   version: "test",
                   capacity: %{"available_turn_slots" => 1}
                 },
                 %{authenticated?: true, transport_route: route}
               )

      assert {:error, {:missing, "version"}} =
               ActorRuntime.admit_worker_ready(
                 %{
                   worker_id: "worker-missing-version",
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
                 worker_id: "worker-a"
               )

      assert command =~ "docker run --rm"
      assert command =~ "--cap-add SYS_ADMIN"
      assert command =~ "--security-opt seccomp=unconfined"
      assert command =~ "--security-opt systempaths=unconfined"
      assert command =~ "--add-host host.docker.internal=host-gateway"
      refute command =~ "DATABASE_URL"
      assert command =~ "WORKER_ID='worker-a'"
      assert command =~ "RUNTIME_FABRIC_URL='tcp://:"
      assert command =~ "@127.0.0.1:6010'"
      refute command =~ "ANKOLE_RUNTIME_FABRIC_ENDPOINT"
      refute command =~ "ANKOLE_AGENT_COMPUTER_WORKER_ID"
      refute command =~ "ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN"
      refute command =~ "ANKOLE_AGENT_COMPUTER_WORKER_INSTANCE_ID"
      refute command =~ "ANKOLE_WORKSPACE_ROOT"
      refute command =~ "ANKOLE_WORKSPACE_SESSIONS_ROOT"
      refute command =~ "ANKOLE_SHARED_FS_ROOT"
      assert command =~ "/workspace/shared"
      refute command =~ "ANKOLE_USER_FILES_ROOT"
      assert command =~ "$PWD/.ankole-worker/shared/user-files"
      refute command =~ "ANKOLE_AGENT_INSTALLED_SKILLS_ROOT"
      assert command =~ "$PWD/.ankole-worker/shared/skills/agents"
      refute command =~ "ANKOLE_BUILTIN_SKILLS_ROOT"
      refute command =~ "/repo/app/library/skills"
      assert command =~ ":/workspace/shared"
      assert command =~ ":/workspace/.sessions"
      refute command =~ "ANKOLE_TIGERFS_MOUNT_ROOT"
      refute command =~ "--device /dev/fuse"
      refute command =~ ":/workspace/library-containers"
      refute command =~ "ANKOLE_AGENT_UID"
      refute command =~ "--agent-uid"
    end

    test "worker bootstrap embeds the global worker auth key without exposing Postgres" do
      assert {:ok, command} =
               WorkerBootstrap.docker_run_command(
                 endpoint: "tcp://127.0.0.1:6010",
                 worker_id: "worker-token"
               )

      assert command =~ "RUNTIME_FABRIC_URL"
      refute command =~ "DATABASE_URL"
      refute command =~ "ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN"

      assert {:ok, worker_auth_key} = WorkerAuthKey.ensure()
      assert command =~ worker_auth_key
    end
  end
end
