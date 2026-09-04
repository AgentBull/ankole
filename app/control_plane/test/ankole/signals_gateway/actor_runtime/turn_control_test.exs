defmodule Ankole.SignalsGateway.ActorRuntime.TurnControlTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.SignalsGateway.ActorRuntime.TurnControl
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef

  @event_id "019a7d15-6b54-7ed9-ae76-78f7fd91e4d5"
  @steer_event_id "019a7d15-6b54-7ed9-ae76-78f7fd91e4d6"
  @other_event_id "019a7d15-6b54-7ed9-ae76-78f7fd91e4d7"

  describe "collect/4" do
    test "builds one control per worker turn from the deliveries" do
      for {label, deliveries, expected} <- collect_table() do
        assert TurnControl.collect(deliveries, :retry, "command.retry") == expected, label
      end
    end

    test "keeps the verb, normalizes the reason, and carries the payload" do
      assert [%{verb: :skill_disabled, reason: nil, payload: %{"skill_names" => ["pdf"]}}] =
               TurnControl.collect([delivery()], :skill_disabled, nil,
                 payload: %{"skill_names" => ["pdf"]}
               )

      assert [%{verb: :stop, reason: "removed", payload: %{}}] =
               TurnControl.collect([delivery()], :stop, :removed)
    end
  end

  describe "dispatch/1" do
    test "sends one turn_control envelope per control and reports the outcome" do
      route = unique_route()
      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)

      stop = %{route: route, turn_ref: fence(), verb: :stop, reason: "command.stop", payload: %{}}

      disable = %{
        route: route,
        turn_ref: fence(),
        verb: :skill_disabled,
        reason: nil,
        payload: %{"skill_names" => ["pdf"]}
      }

      assert [
               %{verb: :stop, send_outcome: "sent_or_queued"},
               %{verb: :skill_disabled, send_outcome: "sent_or_queued"}
             ] = TurnControl.dispatch([stop, disable])

      assert_receive {:actor_lane, stop_envelope}
      control = envelope_body!(stop_envelope, :turn_control)
      assert control.command == "stop"
      assert control.turn == TurnRef.to_proto(fence())
      assert Torque.decode!(control.payload_json) == %{"reason" => "command.stop"}

      assert_receive {:actor_lane, disable_envelope}
      control = envelope_body!(disable_envelope, :turn_control)
      assert control.command == "skill_disabled"
      assert Torque.decode!(control.payload_json) == %{"skill_names" => ["pdf"]}
    end

    test "a route that cannot receive is marked unusable" do
      route = unique_route()
      assert {:ok, %AgentComputerWorker{status: "ready"} = worker} = admit_worker(route)

      control = %{
        route: route,
        turn_ref: fence(),
        verb: :retry,
        reason: "command.retry",
        payload: %{}
      }

      assert [%{send_outcome: "unknown_route", send_error: :unknown_route}] =
               TurnControl.dispatch([control])

      assert %AgentComputerWorker{status: "stale", stop_reason: "unknown_route"} =
               Repo.get_by!(AgentComputerWorker, worker_id: worker.worker_id)
    end
  end

  defp collect_table do
    main = delivery()
    steer = delivery(actor_event_id: @steer_event_id, revision: 1, attempt_no: 1)

    [
      {"no deliveries give no controls", [], []},
      {"one delivery gives one control", [main], [control(main)]},
      {"steer revisions of one turn collapse into the newest fence", [main, steer],
       [control(steer)]},
      {"a delivery without route and worker is dropped",
       [delivery(transport_route: nil, worker_id: nil)], []},
      {"the worker id is the fallback route", [delivery(transport_route: nil)],
       [control(delivery(transport_route: nil))]},
      {"two routes keep two controls", [main, delivery(transport_route: "route-2")],
       [control(main), control(delivery(transport_route: "route-2"))]},
      {"two activations keep two controls",
       [main, delivery(activation_uid: "activation-2", actor_epoch: 2)],
       [control(main), control(delivery(activation_uid: "activation-2", actor_epoch: 2))]},
      {"another turn fence keeps its own control",
       [main, delivery(actor_event_id: @other_event_id, actor_event_id_fence: @other_event_id)],
       [
         control(main),
         control(delivery(actor_event_id: @other_event_id, actor_event_id_fence: @other_event_id))
       ]}
    ]
  end

  defp control(%ActorEventDelivery{} = delivery) do
    %{
      route: delivery.transport_route || delivery.worker_id,
      turn_ref: TurnRef.from_delivery(delivery),
      verb: :retry,
      reason: "command.retry",
      payload: %{}
    }
  end

  defp delivery(overrides \\ []) do
    struct!(
      %ActorEventDelivery{
        actor_event_id: @event_id,
        agent_uid: "agent-a",
        session_id: "session-1",
        activation_uid: "activation-1",
        actor_epoch: 1,
        actor_event_id_fence: @event_id,
        revision: 0,
        attempt_no: 1,
        worker_id: "worker-1",
        transport_route: "route-1",
        state: "sent"
      },
      overrides
    )
  end

  defp fence do
    %TurnRef{
      agent_uid: "agent-a",
      session_id: "session-1",
      activation_uid: "activation-1",
      actor_epoch: 1,
      actor_event_id: @event_id,
      revision: 0
    }
  end
end
