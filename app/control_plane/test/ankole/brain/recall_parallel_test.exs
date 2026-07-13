defmodule Ankole.Brain.Recall.ParallelTest do
  use ExUnit.Case, async: false

  alias Ankole.Brain.Recall.Parallel

  test "normalizes route errors and exits while healthy siblings still return" do
    caller = self()

    outcome =
      Parallel.run([
        {"failed", fn -> raise "route exploded" end},
        {"disabled", fn -> {:error, :not_configured} end},
        {"healthy",
         fn ->
           send(caller, :healthy_route_ran)
           {:ok, [:evidence]}
         end}
      ])

    assert_receive :healthy_route_ran

    assert outcome.results == %{
             "disabled" => [],
             "failed" => [],
             "healthy" => [:evidence]
           }

    assert [failed_reason, "disabled unavailable: :not_configured"] =
             outcome.degraded_reasons

    assert String.starts_with?(failed_reason, "failed exited: ")
  end

  test "all routes share one deadline and timed-out tasks are killed" do
    caller = self()
    timeout = 60

    outcome =
      Parallel.run(
        [
          {"slow-a", blocking_route(caller, :slow_a, :infinity)},
          {"slow-b", blocking_route(caller, :slow_b, timeout + 30)},
          {"healthy", fn -> {:ok, [:ready]} end}
        ],
        timeout: timeout
      )

    assert outcome.results == %{
             "healthy" => [:ready],
             "slow-a" => [],
             "slow-b" => []
           }

    assert outcome.degraded_reasons == ["slow-a timed out", "slow-b timed out"]

    assert_receive {:route_started, :slow_a, slow_a}
    assert_receive {:route_started, :slow_b, slow_b}
    assert_task_stopped(slow_a)
    assert_task_stopped(slow_b)
  end

  defp blocking_route(caller, name, timeout) do
    fn ->
      send(caller, {:route_started, name, self()})

      receive do
        :finish -> {:ok, [:late]}
      after
        timeout -> {:ok, [:late]}
      end
    end
  end

  defp assert_task_stopped(pid) do
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 100
  end
end
