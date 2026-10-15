defmodule Ankole.AgentWorkers.TurnControlTest do
  use Ankole.SessionsCase

  alias Ankole.Sessions.TurnControl
  alias Ankole.Sessions.JobTurnRef

  @event_id "019a7d15-6b54-7ed9-ae76-78f7fd91e4d5"

  describe "dispatch/1" do
    test "sends one turn_control envelope per control on the Agent's connection" do
      %{principal: agent} = agent_fixture()
      route = unique_route()
      :ok = WorkerRoute.register_local_worker(route, self())
      on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
      assert {:ok, %AgentWorker{state: "ready"}} = admit_worker(route, %{worker_id: agent.uid})

      turn_ref = fence(agent.uid)
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

    test "a connection that cannot receive is marked unusable" do
      %{principal: agent} = agent_fixture()
      route = unique_route()
      assert {:ok, %AgentWorker{state: "ready"}} = admit_worker(route, %{worker_id: agent.uid})

      control = %{turn_ref: fence(agent.uid), verb: :retry, reason: "command.retry", payload: %{}}

      assert :ok = TurnControl.dispatch([control])

      assert %AgentWorker{state: "stale", transport_route: nil} =
               Repo.get!(AgentWorker, agent.uid)
    end

    test "a control for an Agent without a connected Worker is not sent" do
      %{principal: agent} = agent_fixture()
      control = %{turn_ref: fence(agent.uid), verb: :stop, reason: nil, payload: %{}}

      assert :ok = TurnControl.dispatch([control])

      refute_receive {:actor_lane, _envelope}
    end
  end

  defp fence(agent_uid) do
    %JobTurnRef{
      agent_uid: agent_uid,
      session_id: "job:1000",
      job_id: 1000,
      attempt: 1,
      signal_id: @event_id
    }
  end
end
