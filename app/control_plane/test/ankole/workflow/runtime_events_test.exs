defmodule Ankole.Workflow.RuntimeEventsTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.Repo
  alias Ankole.RuntimeEvents
  alias Ankole.RuntimeEvents.Handlers
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.Workflow
  alias Ankole.Workflow.RunServer
  alias Ankole.Workflow.Schemas.AgentCall
  alias Ankole.Workflow.Schemas.Run

  test "the typed handler reconstructs a killed running server without duplicate work" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)
    event = workflow_run_ready_event(run.id)

    assert :ok = Handlers.handle(event)
    first_server = wait_for(fn -> RunServer.whereis(run.id) end)
    call = wait_for(fn -> Repo.get_by(AgentCall, run_id: run.id, call_seq: 0) end)
    wait_for_idle_server(run.id, first_server)

    first_monitor = Process.monitor(first_server)
    Process.exit(first_server, :kill)
    assert_receive {:DOWN, ^first_monitor, :process, ^first_server, :killed}, 1_000
    wait_for(fn -> is_nil(RunServer.whereis(run.id)) end)

    assert :ok = Handlers.handle(event)

    second_server =
      wait_for(fn ->
        case RunServer.whereis(run.id) do
          pid when is_pid(pid) and pid != first_server -> pid
          _pid -> nil
        end
      end)

    wait_for_idle_server(run.id, second_server)
    wait_for(fn -> Repo.get(AgentCall, call.id) end)
    assert Repo.aggregate(AgentCall, :count) == 1
    dispatch_source_event_id = "workflow:call:#{call.id}:dispatch"

    assert Repo.aggregate(
             from(stored in ActorEvent,
               where: stored.source_event_id == ^dispatch_source_event_id
             ),
             :count
           ) == 1

    stop_server(second_server)
  end

  test "snapshot recovery finishes cleanup for a cancelled run after its server dies" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)
    ready_event = workflow_run_ready_event(run.id)

    assert :ok = Handlers.handle(ready_event)
    server = wait_for(fn -> RunServer.whereis(run.id) end)
    call = wait_for(fn -> Repo.get_by(AgentCall, run_id: run.id, call_seq: 0) end)
    wait_for_idle_server(run.id, server)

    assert {:ok, %{run: %Run{status: "cancelled"}}} =
             Workflow.cancel_in_storage(run.id, agent.uid)

    assert %AgentCall{status: "cancelled"} = Repo.get!(AgentCall, call.id)

    monitor = Process.monitor(server)
    Process.exit(server, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^server, :killed}, 1_000
    wait_for(fn -> is_nil(RunServer.whereis(run.id)) end)

    workflow_snapshot =
      Handlers.snapshot_events()
      |> Enum.filter(fn {channel, _payload} ->
        channel == RuntimeEvents.workflow_run_ready_channel()
      end)

    assert {RuntimeEvents.workflow_run_ready_channel(), %{"run_id" => run.id}} in workflow_snapshot

    assert :ok = Handlers.handle(ready_event)
    wait_for(fn -> is_nil(RunServer.whereis(run.id)) end)

    assert %Run{status: "cancelled", cleanup_completed_at: %DateTime{}} =
             Repo.get!(Run, run.id)

    assert %AgentCall{status: "cancelled"} = Repo.get!(AgentCall, call.id)

    assert %ActorEvent{type: "command.stop"} =
             Repo.get_by!(ActorEvent,
               agent_uid: agent.uid,
               source_event_id: "workflow:call:#{call.id}:stop"
             )
  end

  test "the snapshot includes running and cleanup-pending runs only" do
    %{principal: agent} = agent_fixture()
    running = run_fixture(agent.uid)

    cleanup_pending =
      for status <- Run.terminal_statuses() do
        run_fixture(agent.uid)
        |> terminalize(status)
      end

    cleaned =
      for status <- Run.terminal_statuses() do
        terminal = run_fixture(agent.uid) |> terminalize(status)
        assert {:ok, cleaned} = Workflow.cleanup_terminal_run(terminal)
        cleaned
      end

    snapshot = Workflow.runtime_event_snapshot()
    handler_snapshot = Handlers.snapshot_events()

    assert {RuntimeEvents.workflow_run_ready_channel(), %{"run_id" => running.id}} in snapshot

    assert {RuntimeEvents.workflow_run_ready_channel(), %{"run_id" => running.id}} in handler_snapshot

    for run <- cleanup_pending do
      assert {RuntimeEvents.workflow_run_ready_channel(), %{"run_id" => run.id}} in snapshot

      assert {RuntimeEvents.workflow_run_ready_channel(), %{"run_id" => run.id}} in handler_snapshot
    end

    for run <- cleaned do
      refute {RuntimeEvents.workflow_run_ready_channel(), %{"run_id" => run.id}} in snapshot

      refute {RuntimeEvents.workflow_run_ready_channel(), %{"run_id" => run.id}} in handler_snapshot
    end

    event =
      handler_snapshot
      |> Enum.find(fn {_channel, payload} -> payload["run_id"] == running.id end)
      |> then(fn {channel, payload} -> RuntimeEvents.expand(channel, payload) end)
      |> List.first()

    assert :ok = Handlers.handle(event)
    server = wait_for(fn -> RunServer.whereis(running.id) end)
    wait_for(fn -> Repo.get_by(AgentCall, run_id: running.id, call_seq: 0) end)
    wait_for_idle_server(running.id, server)
    stop_server(server)
  end

  defp workflow_run_ready_event(run_id) do
    RuntimeEvents.workflow_run_ready_channel()
    |> RuntimeEvents.expand(%{"run_id" => run_id})
    |> List.first()
  end

  defp run_fixture(agent_uid) do
    Repo.insert!(
      Run.creation_changeset(%Run{}, %{
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
  end

  defp terminalize(run, status) do
    run
    |> Run.changeset(%{status: status, completed_at: DateTime.utc_now(:microsecond)})
    |> Repo.update!()
  end

  defp stop_server(pid) do
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1_000
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
      nil ->
        Process.sleep(10)
        wait_for(fun, attempts - 1)

      false ->
        Process.sleep(10)
        wait_for(fun, attempts - 1)

      result ->
        result
    end
  end

  defp wait_for(_fun, 0), do: flunk("condition did not become true")
end
