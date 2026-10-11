defmodule Ankole.Workflow.RecoveryTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.Conversations.Reconciler
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.Workflow
  alias Ankole.Workflow.Jobs.PokeRun
  alias Ankole.Workflow.RunServer
  alias Ankole.Workflow.Schemas.AgentCall
  alias Ankole.Workflow.Schemas.Run

  setup do
    servers = DynamicSupervisor.which_children(Ankole.Workflow.RunSupervisor)
    pids = for {_, pid, _, _} <- servers, do: pid

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Ankole.Workflow.RunSupervisor),
          pid not in pids do
        DynamicSupervisor.terminate_child(Ankole.Workflow.RunSupervisor, pid)
      end
    end)
  end

  test "reconciliation restarts replay before the first durable task exists" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)
    owner = self()

    runner = fn _, _, _, _, _ ->
      send(owner, {:replay_started, self()})
      receive do: (:finish -> {:error, :unexpected_finish})
    end

    assert {:ok, server} = RunServer.ensure_started(run.id, runner: runner)
    assert :ok = perform_job(PokeRun, %{run_id: run.id})
    assert_receive {:replay_started, _}, 1_000
    refute Repo.get_by(AgentCall, run_id: run.id)
    refute Repo.get_by(ActorEvent, agent_uid: agent.uid)
    refute_enqueued(worker: PokeRun, args: %{run_id: run.id})
    stop_server(server)

    assert :ok = perform_job(Reconciler, %{})
    assert_enqueued(worker: PokeRun, args: %{run_id: run.id})
    assert :ok = perform_job(PokeRun, %{run_id: run.id})
    call = wait_for(fn -> Repo.get_by(AgentCall, run_id: run.id, call_seq: 0) end)
    assert call.status == "queued"

    assert %ActorEvent{input_state: "open"} =
             Repo.get_by!(ActorEvent, source_event_id: "workflow:call:#{call.id}:dispatch")
  end

  test "reconciliation reconstructs a killed server without duplicate tasks" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)

    assert :ok = perform_job(PokeRun, %{run_id: run.id})
    first_server = wait_for(fn -> RunServer.whereis(run.id) end)
    call = wait_for(fn -> Repo.get_by(AgentCall, run_id: run.id, call_seq: 0) end)
    wait_for_idle_server(run.id, first_server)
    stop_server(first_server)

    assert :ok = perform_job(Reconciler, %{})
    assert_enqueued(worker: PokeRun, args: %{run_id: run.id})
    assert :ok = perform_job(PokeRun, %{run_id: run.id})
    second_server = wait_for(fn -> RunServer.whereis(run.id) end)
    assert second_server != first_server
    wait_for_idle_server(run.id, second_server)
    assert Repo.aggregate(from(call in AgentCall, where: call.run_id == ^run.id), :count) == 1
    source_event_id = "workflow:call:#{call.id}:dispatch"

    assert Repo.aggregate(
             from(event in ActorEvent, where: event.source_event_id == ^source_event_id),
             :count
           ) == 1
  end

  test "reconciliation finishes cleanup for a cancelled run after its server dies" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)

    assert :ok = perform_job(PokeRun, %{run_id: run.id})
    server = wait_for(fn -> RunServer.whereis(run.id) end)
    call = wait_for(fn -> Repo.get_by(AgentCall, run_id: run.id, call_seq: 0) end)
    wait_for_idle_server(run.id, server)

    assert {:ok, %{run: %Run{status: "cancelled"}}} =
             Repo.transact(fn repo -> Workflow.cancel_in_tx(repo, run.id, agent.uid) end)

    assert %AgentCall{status: "cancelled"} = Repo.get!(AgentCall, call.id)
    stop_server(server)

    assert :ok = perform_job(Reconciler, %{})
    assert_enqueued(worker: PokeRun, args: %{run_id: run.id})
    assert :ok = perform_job(PokeRun, %{run_id: run.id})

    wait_for(fn ->
      match?(%DateTime{}, Repo.get!(Run, run.id).cleanup_completed_at)
    end)

    assert %ActorEvent{type: "command.stop"} =
             Repo.get_by!(ActorEvent,
               agent_uid: agent.uid,
               source_event_id: "workflow:call:#{call.id}:stop"
             )
  end

  test "reconciliation selects absent running and cleanup-pending servers only" do
    %{principal: agent} = agent_fixture()
    running = run_fixture(agent.uid)
    live = run_fixture(agent.uid)
    owner = self()

    runner = fn _, _, _, _, _ ->
      send(owner, :live_replay_started)
      receive do: (:finish -> {:error, :unexpected_finish})
    end

    assert :ok = RunServer.poke(live.id, runner: runner)
    assert_receive :live_replay_started, 1_000

    pending =
      for status <- Run.terminal_statuses(), do: run_fixture(agent.uid) |> terminalize(status)

    cleaned =
      for status <- Run.terminal_statuses() do
        terminal = run_fixture(agent.uid) |> terminalize(status)
        assert {:ok, cleaned} = Workflow.cleanup_terminal_run(terminal)
        cleaned
      end

    assert :ok = perform_job(Reconciler, %{})
    assert_enqueued(worker: PokeRun, args: %{run_id: running.id})
    for run <- pending, do: assert_enqueued(worker: PokeRun, args: %{run_id: run.id})
    for run <- cleaned, do: refute_enqueued(worker: PokeRun, args: %{run_id: run.id})
    refute_enqueued(worker: PokeRun, args: %{run_id: live.id})
  end

  test "site reconciliation restores running work in both tenants including a suspended tenant",
       %{tenant: tenant} do
    %{principal: first} = agent_fixture()
    first_run = run_fixture(first.uid)
    other = create_tenant()

    second_run =
      Repo.with_tenant(other.id, fn ->
        %{principal: second} = agent_fixture()
        run_fixture(second.uid)
      end)

    Repo.update!(Ecto.Changeset.change(other, suspended_at: DateTime.utc_now()))
    assert :ok = perform_job(Reconciler, %{})
    assert_enqueued(worker: PokeRun, args: %{run_id: first_run.id, tenant_id: tenant.id})
    assert_enqueued(worker: PokeRun, args: %{run_id: second_run.id, tenant_id: other.id})
    assert Repo.tenant_id!() == tenant.id
  end

  defp run_fixture(agent_uid) do
    Repo.insert!(
      Run.creation_changeset(%Run{}, %{
        authorization_kind: "service",
        agent_uid: agent_uid,
        owner_session_id: "owner-#{System.unique_integer([:positive])}",
        reply_route: %{"binding_name" => "bot"},
        source_tool_call_id: "tool-#{System.unique_integer([:positive])}",
        title: "Recover Workflow",
        script: "return await agent('Recover the task');",
        args: %{},
        status: "running",
        concurrency: 8,
        max_agent_calls: 256,
        error: %{}
      })
    )
    |> Ankole.SignalsGateway.ActorRuntimeCase.stub_workflow_drivers()
  end

  defp terminalize(run, status) do
    run
    |> Run.changeset(%{status: status, completed_at: DateTime.utc_now(:microsecond)})
    |> Repo.update!()
  end

  defp stop_server(pid) do
    run_id = :sys.get_state(pid).run_id
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1_000
    wait_for(fn -> is_nil(RunServer.whereis(run_id)) end)
  end

  defp wait_for_idle_server(run_id, pid) do
    wait_for(fn ->
      case RunServer.whereis(run_id) do
        ^pid -> if is_nil(:sys.get_state(pid).replay), do: pid
        _pid -> nil
      end
    end)
  end

  defp wait_for(fun, attempts \\ 200)

  defp wait_for(fun, attempts) when attempts > 0 do
    case fun.() do
      value when value in [nil, false] ->
        Process.sleep(10)
        wait_for(fun, attempts - 1)

      value ->
        value
    end
  end

  defp wait_for(_fun, 0), do: flunk("condition did not become true")
end
