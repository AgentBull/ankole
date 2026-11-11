defmodule Ankole.AgentWorkers.TurnControlTest do
  use Ankole.SessionsCase

  import Ankole.PrincipalsFixtures, only: [human_fixture: 0]

  alias Ankole.AgentWorkers.RunnerDevices
  alias Ankole.AuthZ.Actor
  alias Ankole.Sessions.TurnControl
  alias Ankole.Sessions.JobTurnRef

  describe "dispatch/1" do
    test "sends one turn_control envelope per control on the Agent's connection" do
      %{principal: agent} = agent_fixture()
      route = unique_route()
      :ok = WorkerRoute.register_local_worker(route, self())
      on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
      assert {:ok, %AgentWorker{state: :ready}} = admit_worker(route, %{worker_id: agent.uid})

      turn_ref = job_turn_ref(agent.uid)
      stop = %{turn_ref: turn_ref, verb: :stop, reason: "command.stop", payload: %{}}

      disable = %{
        turn_ref: turn_ref,
        verb: :skill_disabled,
        reason: nil,
        payload: %{"skill_names" => ["pdf"]}
      }

      assert :ok = TurnControl.dispatch([stop, disable])

      assert_receive {:actor_lane, stop_envelope}
      control = envelope_body!(stop_envelope, :turn_control)
      assert control.command == "stop"
      assert control.turn == JobTurnRef.to_proto(turn_ref)
      assert Torque.decode!(control.payload_json) == %{"reason" => "command.stop"}

      assert_receive {:actor_lane, disable_envelope}
      control = envelope_body!(disable_envelope, :turn_control)
      assert control.command == "skill_disabled"
      assert Torque.decode!(control.payload_json) == %{"skill_names" => ["pdf"]}
    end

    test "a control for a Job on a paired device goes to the device's connection" do
      %{principal: owner} = human_fixture()

      %{principal: agent} =
        agent_fixture(%{type: :personal_assistant, owner_principal_uid: owner.uid})

      origin = "https://ankole.example.test"

      assert {:ok, %{id: runner_id, code: code}} =
               RunnerDevices.register(Actor.new(owner), "Research machine", origin)

      assert {:ok, %{token: token}} = RunnerDevices.pair(code)
      assert {:ok, [spec]} = RunnerDevices.bootstrap(token, origin)

      test_process = self()
      managed_route = unique_route()
      device_route = unique_route()
      :ok = WorkerRoute.register_local_worker(managed_route, test_process)

      :ok =
        WorkerRoute.register_local_worker(device_route, fn envelope ->
          send(test_process, {:device_lane, envelope})
        end)

      on_exit(fn ->
        WorkerRoute.unregister_local_worker(managed_route)
        WorkerRoute.unregister_local_worker(device_route)
      end)

      assert {:ok, %AgentWorker{state: :ready}} =
               admit_worker(managed_route, %{worker_id: agent.uid})

      assert {:ok, _binding} =
               AgentWorkers.admit_join(
                 %{incarnation_id: "device-" <> device_route, max_slots: 1, available_slots: 1},
                 %{
                   transport_route: device_route,
                   worker_id: spec.agent_uid,
                   runner_id: runner_id,
                   generation: spec.generation
                 }
               )

      turn_ref =
        job_turn_ref(agent.uid, %{
          "created_by" => %{"principal_uid" => to_string(Ankole.ActorRef.from_principal(owner))},
          "runner_id" => runner_id
        })

      control = %{turn_ref: turn_ref, verb: :stop, reason: "command.stop", payload: %{}}

      assert :ok = TurnControl.dispatch([control])

      assert_receive {:device_lane, envelope}
      control = envelope_body!(envelope, :turn_control)
      assert control.command == "stop"
      assert control.turn == JobTurnRef.to_proto(turn_ref)
      refute_received {:actor_lane, _envelope}
    end

    test "a connection that cannot receive is marked unusable" do
      %{principal: agent} = agent_fixture()
      route = unique_route()
      assert {:ok, %AgentWorker{state: :ready}} = admit_worker(route, %{worker_id: agent.uid})

      control = %{
        turn_ref: job_turn_ref(agent.uid),
        verb: :retry,
        reason: "command.retry",
        payload: %{}
      }

      assert :ok = TurnControl.dispatch([control])

      assert %AgentWorker{state: :stale, transport_route: nil} =
               Repo.get_by!(AgentWorker, agent_uid: agent.uid)
    end

    test "a control for an Agent without a connected Worker is not sent" do
      %{principal: agent} = agent_fixture()
      control = %{turn_ref: job_turn_ref(agent.uid), verb: :stop, reason: nil, payload: %{}}

      assert :ok = TurnControl.dispatch([control])

      refute_receive {:actor_lane, _envelope}
    end
  end

  # TurnControl reads the Job to learn which Worker runs it, so each fence
  # names a Job that exists. The Job runs on the Agent's managed Worker unless
  # `attrs` names a device.
  defp job_turn_ref(agent_uid, attrs \\ nil) do
    attrs = attrs || %{"source_signal_id" => Ankole.WorkFixtures.service_source(agent_uid).id}

    assert {:ok, %{job: job, dispatch_event: dispatch}} =
             create_job_with_stub_driver(
               Map.merge(attrs, %{
                 "agent_uid" => agent_uid,
                 "owner_session_id" => "owner-session-turn-control",
                 "source_tool_call_id" => "tool-turn-control",
                 "title" => "Turn control Job",
                 "task" => "Run the analysis.",
                 "reply_route" => %{"binding_name" => "bot"}
               })
             )

    %JobTurnRef{
      agent_uid: agent_uid,
      session_id: dispatch.session_id,
      job_id: job.id,
      attempt: 1,
      signal_id: dispatch.id
    }
  end
end
