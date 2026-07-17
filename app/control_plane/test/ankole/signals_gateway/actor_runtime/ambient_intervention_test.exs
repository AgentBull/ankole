defmodule Ankole.SignalsGateway.ActorRuntime.AmbientInterventionTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  setup do
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)
    :ok
  end

  test "supersedes an older ambient scene and delivers only the latest stable scene" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    assert {:ok, %{actor_event: first_event}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{
                 source_event_id: "ambient-first-event",
                 source_entry_id: "ambient-first-entry",
                 text: "Which benchmark should we use?"
               }),
               now: @base_time
             )

    second_at = DateTime.add(@base_time, 20, :second)

    assert {:ok, %{actor_event: second_event}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{
                 source_event_id: "ambient-second-event",
                 source_entry_id: "ambient-second-entry",
                 text: "Use CSI 300.",
                 provider_time: second_at
               }),
               now: second_at
             )

    first_snapshot = first_event.payload["data"]["ambient_batch"]
    third_at = DateTime.add(@base_time, 40, :second)

    assert {:ok, %{actor_event: third_event}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{
                 source_event_id: "ambient-third-event",
                 source_entry_id: "ambient-third-entry",
                 text: "Use the total-return series.",
                 provider_time: third_at
               }),
               now: third_at
             )

    third_snapshot = third_event.payload["data"]["ambient_batch"]

    assert is_binary(first_snapshot["scene_fingerprint"])
    assert is_binary(first_snapshot["as_of"])
    assert is_binary(first_snapshot["expires_at"])
    refute first_snapshot["scene_fingerprint"] == third_snapshot["scene_fingerprint"]

    process_at = DateTime.add(third_event.available_at, 1, :second)

    assert {:ok,
            %{
              status: :ambient_superseded,
              reason: :scene_changed,
              actor_event: superseded_event,
              superseded_count: 2
            }} = process_ready_events_once(now: process_at)

    assert superseded_event.id == first_event.id
    assert %DateTime{} = Repo.get!(ActorEvent, first_event.id).completed_at
    assert %DateTime{} = Repo.get!(ActorEvent, second_event.id).completed_at
    assert is_nil(Repo.get!(ActorEvent, third_event.id).completed_at)
    refute_receive {:actor_lane, _envelope}, 50

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_events_once(now: process_at, lease_seconds: @long_lease_seconds)

    assert_receive {:actor_lane, envelope}
    assert turn_start_payload!(envelope).actor_event.actor_event_id == third_event.id
  end

  test "expires a queued ambient opportunity without starting a worker turn" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    assert {:ok, %{actor_event: event}} =
             emit_entry(agent.uid, "bot", group_entry(%{text: "Could this be useful?"}),
               now: @base_time
             )

    {:ok, expires_at, _offset} =
      event.payload["data"]["ambient_batch"]["expires_at"]
      |> DateTime.from_iso8601()

    assert {:ok,
            %{
              status: :ambient_superseded,
              reason: :expired,
              actor_event: completed_event
            }} = process_ready_events_once(now: expires_at)

    assert completed_event.id == event.id
    refute_receive {:actor_lane, _envelope}, 50
    refute Repo.get_by(ActorEventDelivery, actor_event_id: event.id)
  end

  test "does not stale an ambient scene on an exact provider redelivery" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    entry =
      group_entry(%{
        source_event_id: "ambient-redelivery-event",
        source_entry_id: "ambient-redelivery-entry",
        text: "The strategy may need a backtest."
      })

    assert {:ok, %{actor_event: event}} =
             emit_entry(agent.uid, "bot", entry, now: @base_time)

    assert {:ok, %{status: :duplicate}} =
             Ingress.emit_entry(agent.uid, "bot", entry,
               now: DateTime.add(@base_time, 20, :second)
             )

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_events_once(
               now: DateTime.add(@base_time, 21, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, envelope}
    assert turn_start_payload!(envelope).actor_event.actor_event_id == event.id
  end

  test "supersedes queued ambient work after its binding policy changes" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    assert {:ok, %{actor_event: event}} =
             emit_entry(agent.uid, "bot", group_entry(%{}), now: @base_time)

    binding_fixture(agent.uid, "bot", :record_only)

    assert {:ok,
            %{
              status: :ambient_superseded,
              reason: :binding_policy_changed,
              actor_event: completed_event
            }} = process_ready_events_once(now: DateTime.add(@base_time, 20, :second))

    assert completed_event.id == event.id
    refute_receive {:actor_lane, _envelope}, 50
  end
end
