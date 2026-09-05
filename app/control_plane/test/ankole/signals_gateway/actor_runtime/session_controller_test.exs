defmodule Ankole.SignalsGateway.ActorRuntime.SessionControllerTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_until: 2]

  alias Ankole.SignalsGateway.ActorRuntime.{ActorDirectory, SessionController, SessionSupervisor}

  test "an idle controller exits normally and a later wake starts a new one" do
    %{principal: agent} = agent_fixture()
    key = %{agent_uid: agent.uid, session_id: "idle-session"}
    pid = controller(key)
    monitor = Process.monitor(pid)
    send(pid, :timeout)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    assert GenServer.whereis(ActorDirectory.via(key)) == nil
    assert {:ok, %{status: :idle}} = SessionController.process_ready(key)
    refute GenServer.whereis(ActorDirectory.via(key)) == pid
  end

  test "a ready call queued behind retirement retries on the new controller" do
    %{principal: agent} = agent_fixture()
    key = %{agent_uid: agent.uid, session_id: "idle-wake-race"}
    pid = controller(key)
    :ok = :sys.suspend(pid)
    send(pid, :timeout)
    call = Task.async(fn -> SessionController.process_ready(key) end)

    try do
      assert {:ok, true} =
               wait_until(deadline(2_000), fn ->
                 {:messages, messages} = Process.info(pid, :messages)
                 Enum.any?(messages, &match?({:"$gen_call", _from, {:process_ready, _opts}}, &1))
               end)
    after
      :sys.resume(pid)
    end

    assert {:ok, %{status: :idle}} = Task.await(call)
    refute GenServer.whereis(ActorDirectory.via(key)) == pid
  end

  test "a live delivery prevents retirement until the terminal transition" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    assert {:ok, %{actor_event: input}} =
             emit_entry(agent.uid, "bot", group_entry(%{text: "PING", explicit: true}),
               now: @base_time
             )

    key = %{agent_uid: agent.uid, session_id: input.session_id}
    pid = controller(key)

    assert {:ok, %{send_outcome: "sent_or_queued", turn_ref: ref}} =
             SessionController.process_ready(key,
               now: DateTime.add(@base_time, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, envelope}
    turn = turn_start_payload!(envelope).turn
    send(pid, :timeout)

    :ok =
      SessionController.dispatch_inbound(key, route, %FabricProto.Envelope{
        body: {:turn_accepted, turn_accepted_payload(turn)}
      })

    assert :sys.get_state(pid).actor_key == key
    assert Repo.get_by!(ActorEventDelivery, actor_event_id: input.id).state == "accepted"

    assert {:ok, _} =
             ActorRuntime.handle_turn_error(
               ref,
               turn_error_reason("worker_loop_failed", "test failure", %{})
             )

    monitor = Process.monitor(pid)
    send(pid, :timeout)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
  end

  defp controller(key) do
    {:ok, pid} = SessionSupervisor.ensure_session_controller(key)

    on_exit(fn ->
      if current = GenServer.whereis(ActorDirectory.via(key)),
        do: DynamicSupervisor.terminate_child(SessionSupervisor, current)
    end)

    pid
  end
end
