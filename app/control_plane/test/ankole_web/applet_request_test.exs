defmodule AnkoleWeb.AppletRequestTest do
  @moduledoc "Unit checks use a fake transport and the Task message protocol."
  use ExUnit.Case, async: true

  alias AnkoleWeb.AppletRequest

  @max_pipeline_bytes 1_048_576

  defmodule Transport do
    @moduledoc false

    def setopts(%{owner: owner} = socket, options) do
      send(owner, {socket, :setopts, options})
      :ok
    end

    def close(%{owner: owner} = socket) do
      send(owner, {socket, :closed})
      :ok
    end
  end

  test "an oversized initial buffer closes the socket and cancels the invocation before arming" do
    {conn, raw} = connection(String.duplicate("x", @max_pipeline_bytes + 1))
    task = invocation()
    send(self(), {task.ref, :done})

    assert_raise Bandit.TransportError, fn -> AppletRequest.await(conn, task) end

    assert_received {^raw, :closed}
    refute_received {^raw, :setopts, [active: :once]}
    assert_cancelled(task)
  end

  test "the exact budget preserves initial, received, and drained bytes in order" do
    initial = ["start", [":"]]
    middle = String.duplicate("m", @max_pipeline_bytes - 9)
    last = "end"
    {conn, raw} = connection(initial)
    task = invocation()
    send(self(), {:tcp, raw, middle})
    send(self(), {task.ref, :done})
    send(self(), {:tcp, raw, last})

    assert {restored, {:ok, :done}} = AppletRequest.await(conn, task)
    {Bandit.Adapter, %{transport: transport}} = restored.adapter

    assert byte_size(transport.buffer) == @max_pipeline_bytes
    assert transport.buffer == IO.iodata_to_binary([initial, middle, last])
    refute_received {^raw, :closed}
    assert_cancelled(task)
  end

  test "draining after the task result uses the remaining budget and cancels on overflow" do
    initial = "start:"
    {conn, raw} = connection(initial)
    task = invocation()
    send(self(), {task.ref, :done})
    send(self(), {:tcp, raw, String.duplicate("x", @max_pipeline_bytes - byte_size(initial))})
    send(self(), {:tcp, raw, "!"})
    send(self(), {:tcp, raw, "unread"})

    assert_raise Bandit.TransportError, fn -> AppletRequest.await(conn, task) end

    assert_received {^raw, :closed}
    assert_received {:tcp, ^raw, "unread"}
    assert_cancelled(task)
  end

  defp connection(initial) do
    raw = %{owner: self(), id: make_ref()}

    socket = %ThousandIsland.Socket{
      socket: raw,
      transport_module: Transport,
      read_timeout: 5_000,
      handshake_timeout: 5_000,
      silent_terminate_on_error: false,
      span: nil,
      peername: {{127, 0, 0, 1}, 12_345}
    }

    transport = %Bandit.HTTP1.Socket{socket: socket, buffer: initial}
    {%Plug.Conn{adapter: {Bandit.Adapter, %{transport: transport}}}, raw}
  end

  defp invocation do
    owner = self()

    pid =
      spawn(fn ->
        monitor = Process.monitor(owner)

        receive do
          :cancel -> send(owner, {:invocation_cancelled, self()})
          {:DOWN, ^monitor, :process, ^owner, _reason} -> :ok
        end
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    %Task{owner: owner, pid: pid, ref: Process.monitor(pid), mfa: {:erlang, :apply, 2}}
  end

  defp assert_cancelled(%Task{pid: pid}) do
    assert_receive {:invocation_cancelled, ^pid}, 1_000
  end
end
