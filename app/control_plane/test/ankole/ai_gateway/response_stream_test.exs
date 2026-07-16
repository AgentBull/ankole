defmodule Ankole.AIGateway.ResponseStreamTest do
  use ExUnit.Case, async: false

  alias Ankole.AIGateway.ResponseStream.Supervisor

  test "a provider waiting for ready does not block other stream starts" do
    test_pid = self()

    slow_open = fn ->
      send(test_pid, {:slow_open_started, self()})

      receive do
        :release_slow_open -> {:error, :released}
      end
    end

    slow_starter = Task.async(fn -> Supervisor.start_stream(stream_opts(slow_open)) end)
    assert {:ok, slow_pid} = Task.await(slow_starter, 1_000)
    assert_receive {:slow_open_started, ^slow_pid}

    fast_open = fn ->
      send(test_pid, {:fast_open_started, self()})
      {:error, :fast_failed}
    end

    fast_starter = Task.async(fn -> Supervisor.start_stream(stream_opts(fast_open)) end)
    assert {:ok, fast_pid} = Task.await(fast_starter, 1_000)
    assert_receive {:fast_open_started, ^fast_pid}

    slow_monitor = Process.monitor(slow_pid)
    fast_monitor = Process.monitor(fast_pid)

    assert {:error, :fast_failed} = GenServer.call(fast_pid, :describe)
    assert_receive {:DOWN, ^fast_monitor, :process, ^fast_pid, :normal}

    send(slow_pid, :release_slow_open)
    assert {:error, :released} = GenServer.call(slow_pid, :describe)

    assert_receive {:DOWN, ^slow_monitor, :process, ^slow_pid, :normal}, 2_000
  end

  defp stream_opts(open_fun) do
    [
      subject_uid: "agent_test",
      request: %{},
      stateful: nil,
      receiver: self(),
      telemetry_spec: %{},
      open_fun: open_fun
    ]
  end
end
