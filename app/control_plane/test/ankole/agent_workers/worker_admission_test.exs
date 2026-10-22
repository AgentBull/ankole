defmodule Ankole.AgentWorkers.WorkerAdmissionTest do
  use Ankole.SessionsCase

  alias Ankole.AgentWorkers
  alias Ankole.AgentWorkers.WorkerAdmission

  test "restored routes expire by heartbeat while fresh routes and generation facts survive" do
    for state <- [:ready, :draining],
        heartbeat <- [nil, DateTime.add(DateTime.utc_now(), -61, :second)] do
      %{principal: agent} = agent_fixture()
      route = unique_route()
      assert {:ok, admitted} = admit_worker(route, %{worker_id: agent.uid})
      assert :ok = WorkerAdmission.expire_connection(agent.uid)
      assert Repo.get!(AgentWorker, agent.uid).transport_route == route

      state_changed_at = DateTime.add(DateTime.utc_now(:microsecond), -120, :second)

      from(w in AgentWorker, where: w.agent_uid == ^agent.uid)
      |> Repo.update_all(
        set: [
          state: state,
          state_changed_at: state_changed_at,
          last_worker_heartbeat_at: heartbeat
        ]
      )

      assert :ok = WorkerAdmission.expire_connection(agent.uid)
      expired = Repo.get!(AgentWorker, agent.uid)
      assert expired.transport_route == nil
      assert expired.generation == admitted.generation
      assert expired.state == if(state == :draining, do: :draining, else: :stale)

      if state == :draining,
        do: assert(expired.state_changed_at == state_changed_at),
        else: assert(DateTime.compare(expired.state_changed_at, state_changed_at) == :gt)

      assert :ok = WorkerAdmission.expire_connection(agent.uid)
      Ankole.DataCase.assert_persisted_equal(Repo.get!(AgentWorker, agent.uid), expired)
    end
  end

  test "join, capacity, drain, and disconnect publish committed Worker facts (G2)" do
    %{principal: agent} = agent_fixture()
    uid = agent.uid
    route = unique_route()
    Phoenix.PubSub.subscribe(Ankole.PubSub, AgentWorkers.topic(uid))

    assert {:ok, worker} =
             admit_worker(route, %{worker_id: uid, capacity: %{"available_slots" => 1}})

    assert_receive {:worker_changed, ^uid}
    assert Repo.get!(AgentWorker, uid).state == :ready

    assert {:ok, _} = report_capacity(worker, route, 0)
    assert_receive {:worker_changed, ^uid}
    assert AgentWorker.available_slots(Repo.get!(AgentWorker, uid)) == 0
    assert {:ok, _} = report_capacity(worker, route, 1)
    assert_receive {:worker_changed, ^uid}
    assert AgentWorker.available_slots(Repo.get!(AgentWorker, uid)) == 1
    assert {:ok, _} = report_capacity(worker, route, 1)
    refute_receive {:worker_changed, ^uid}, 50

    assert {:ok, _} =
             WorkerAdmission.handle_control_shutdown(
               %FabricProto.ControlShutdown{reason: "drain"},
               %{
                 transport_route: route,
                 worker_id: uid
               }
             )

    assert_receive {:worker_changed, ^uid}
    assert Repo.get!(AgentWorker, uid).state == :draining
    assert {:ok, :marked_stale} = WorkerAdmission.mark_route_unusable(route, :socket_closed)
    assert_receive {:worker_changed, ^uid}
    assert Repo.get!(AgentWorker, uid).transport_route == nil
  end

  test "a former connection or process changes neither capacity nor the wake stream (G6)" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    assert {:ok, worker} = admit_worker(route, %{worker_id: agent.uid})
    Phoenix.PubSub.subscribe(Ankole.PubSub, AgentWorkers.topic(agent.uid))
    assert {:error, :stale_transport_route} = report_capacity(worker, unique_route(), 2)

    assert {:error, :stale_transport_route} =
             report_capacity(%{worker | incarnation_id: "former"}, route, 2)

    assert %AgentWorker{capacity: %{"available_slots" => 4}} =
             Repo.get!(AgentWorker, worker.agent_uid)

    refute_receive {:worker_changed, _uid}, 50
  end

  test "a fresh connection rejects a competing incarnation without changing its route" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    assert {:ok, worker} = admit_worker(route, %{worker_id: agent.uid})
    Phoenix.PubSub.subscribe(Ankole.PubSub, AgentWorkers.topic(agent.uid))

    assert {:error, :worker_incarnation_active} =
             admit_worker(unique_route(), %{worker_id: agent.uid, incarnation_id: "competing"})

    Ankole.DataCase.assert_persisted_equal(Repo.get!(AgentWorker, agent.uid), worker)
    refute_receive {:worker_changed, _uid}, 50
  end

  test "the same incarnation reconnects while its heartbeat is fresh" do
    %{principal: agent} = agent_fixture()
    assert {:ok, worker} = admit_worker(unique_route(), %{worker_id: agent.uid})
    route = unique_route()

    assert {:ok, reconnected} =
             admit_worker(route, %{worker_id: agent.uid, incarnation_id: worker.incarnation_id})

    assert reconnected.transport_route == route
    assert reconnected.incarnation_id == worker.incarnation_id
  end

  test "a new incarnation joins after disconnect or heartbeat silence" do
    for condition <- [:disconnected, :silent] do
      %{principal: agent} = agent_fixture()
      route = unique_route()
      assert {:ok, _worker} = admit_worker(route, %{worker_id: agent.uid})

      case condition do
        :disconnected ->
          assert {:ok, :marked_stale} = WorkerAdmission.mark_route_unusable(route, :socket_closed)

        :silent ->
          Repo.update_all(
            from(w in AgentWorker,
              where: w.agent_uid == ^agent.uid,
              update: [
                set: [
                  last_worker_heartbeat_at: fragment("clock_timestamp() - interval '61 seconds'")
                ]
              ]
            ),
            []
          )
      end

      next_route = unique_route()

      assert {:ok, reconnected} =
               admit_worker(next_route, %{worker_id: agent.uid, incarnation_id: "replacement"})

      assert reconnected.transport_route == next_route
      assert reconnected.incarnation_id == "replacement"
    end
  end

  test "a join owns its transaction and runs only as a top-level call" do
    %{principal: agent} = agent_fixture()
    :ok = provision_worker(agent.uid)
    generation = Repo.get!(AgentWorker, agent.uid).generation
    auth = %{transport_route: unique_route(), worker_id: agent.uid, generation: generation}
    ready = %{incarnation_id: "nested", max_slots: 1, available_slots: 1}

    assert_raise Ash.Error.Framework, ~r/must run at the top level/, fn ->
      Repo.transact(fn -> WorkerAdmission.admit_join(ready, auth) end)
    end

    assert Repo.get!(AgentWorker, agent.uid).state == :starting
  end

  defp report_capacity(worker, route, available_slots) do
    AgentWorkers.handle_worker_heartbeat(
      %FabricProto.WorkerHeartbeat{
        incarnation_id: worker.incarnation_id,
        max_slots: 1,
        active_slots: 1 - available_slots,
        available_slots: available_slots
      },
      %{transport_route: route, worker_id: worker.agent_uid}
    )
  end
end
