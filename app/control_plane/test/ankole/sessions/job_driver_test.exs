defmodule Ankole.Sessions.JobDriverTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Ankole.Sessions.JobDriver

  test "failed operations keep their retry and omit private request data from logs" do
    private_request = "private-job-request-#{System.unique_integer([:positive])}"

    for operation <- [:start, :mailbox, :observe] do
      ref = make_ref()
      data = %{tasks: %{ref => {operation, self()}}, mailbox_dirty: false}
      reason = {:task_exit, {:killed, {GenServer, :call, [self(), private_request, 15_000]}}}

      log =
        capture_log([format: "$metadata $message\n", metadata: :all], fn ->
          assert {:keep_state, %{tasks: %{}}, [{:state_timeout, retry_ms, :poll}]} =
                   JobDriver.handle_event(:info, {ref, {:error, reason}}, :running, data)

          assert retry_ms == 60_000
        end)

      assert log =~ "sessions.job_driver.operation_failed"
      assert log =~ "operation=#{operation}"
      refute log =~ private_request
    end
  end

  test "a disconnected observation keeps polling without dispatching start or mailbox" do
    ref = make_ref()

    data = %{
      tasks: %{ref => {:observe, self()}},
      mailbox_dirty: false,
      start_dirty: false,
      observe_dirty: false
    }

    assert {:keep_state, %{tasks: %{}}, [{:state_timeout, 60_000, :poll}]} =
             JobDriver.handle_event(:info, {ref, {:ok, :disconnected}}, :starting, data)

    data = %{
      tasks: %{ref => {:observe, self()}},
      mailbox_dirty: false,
      start_dirty: false,
      observe_dirty: false
    }

    assert {:keep_state, %{tasks: %{}}, [{:state_timeout, 60_000, :poll}]} =
             JobDriver.handle_event(:info, {ref, {:ok, :disconnected}}, :running, data)
  end

  test "an adopt observation arriving during an in-flight start reruns start immediately after failure" do
    start_ref = make_ref()
    observe_ref = make_ref()
    old_worker = %{transport_route: "dead-route"}
    new_worker = %{transport_route: "fresh-route"}

    data = %{
      tasks: %{start_ref => {:start, self()}, observe_ref => {:observe, self()}},
      attempt: %{job_worker: old_worker, job_mode: "start"},
      mailbox_dirty: false,
      start_dirty: false,
      observe_dirty: false
    }

    assert {:next_state, :starting, adopted_data, [{:state_timeout, 60_000, :poll}]} =
             JobDriver.handle_event(
               :info,
               {observe_ref, {:ok, {:adopt, new_worker}}},
               :starting,
               data
             )

    assert adopted_data.start_dirty == true
    assert adopted_data.attempt == %{job_worker: new_worker, job_mode: "adopt"}
    assert Map.keys(adopted_data.tasks) == [start_ref]

    Ankole.Repo.put_tenant_id("019a2b00-0000-7000-8000-000000000001")

    capture_log(fn ->
      assert {:next_state, :starting, retried_data, [{:state_timeout, 60_000, :poll}]} =
               JobDriver.handle_event(
                 :info,
                 {start_ref, {:error, :unknown_route}},
                 :starting,
                 adopted_data
               )

      assert retried_data.start_dirty == false
      assert [{new_ref, {:start, pid}}] = Map.to_list(retried_data.tasks)
      assert new_ref != start_ref
      Task.Supervisor.terminate_child(Ankole.Sessions.Tasks, pid)
      Process.demonitor(new_ref, [:flush])
    end)
  end

  test "a worker_changed signal arriving during an in-flight observe triggers an immediate re-observation" do
    observe_ref = make_ref()

    data = %{
      key: %{agent_uid: "agent-a", session_id: "job:42"},
      attempt: %{job_worker: %{transport_route: "route-1"}, job_mode: "start"},
      tasks: %{observe_ref => {:observe, self()}},
      mailbox_dirty: false,
      start_dirty: false,
      observe_dirty: false
    }

    assert {:keep_state, dirty_data} =
             JobDriver.handle_event(:info, {:worker_changed, "agent-a"}, :starting, data)

    assert dirty_data.observe_dirty == true

    Ankole.Repo.put_tenant_id("019a2b00-0000-7000-8000-000000000001")

    assert {:keep_state, reobserving_data, [{:state_timeout, 60_000, :poll}]} =
             JobDriver.handle_event(
               :info,
               {observe_ref, {:ok, :disconnected}},
               :starting,
               dirty_data
             )

    assert reobserving_data.observe_dirty == false
    assert [{new_ref, {:observe, pid}}] = Map.to_list(reobserving_data.tasks)
    assert new_ref != observe_ref
    Task.Supervisor.terminate_child(Ankole.Sessions.Tasks, pid)
    Process.demonitor(new_ref, [:flush])
  end
end
