defmodule Ankole.FunctionRuntime.AppletClientTest.CapacityPlug do
  import Plug.Conn
  def init(owner), do: owner

  def call(conn, owner) do
    send(owner, {:capacity_rejection, conn.request_path})
    send_resp(conn, 503, "runtime_busy")
  end
end

defmodule Ankole.FunctionRuntime.AppletClientTest.SlowAdmissionPlug do
  import Plug.Conn
  def init(options), do: options

  def call(conn, {owner, stage}) do
    current =
      cond do
        conn.method == "PUT" -> :code
        conn.method == "DELETE" -> :cleanup
        get_req_header(conn, "upgrade") == ["websocket"] -> :upgrade
        true -> :preflight
      end

    if current == stage do
      send(owner, {:slow_admission, stage})
      Process.sleep(2_000)
    end

    send_resp(conn, if(stage == :code and current == :preflight, do: 428, else: 204), "")
  end
end

defmodule Ankole.FunctionRuntime.AppletClientTest do
  use ExUnit.Case, async: false
  alias Ankole.FunctionRuntime.{AppletClient, EndpointPool}

  setup do
    original = :sys.get_state(EndpointPool)
    {:ok, real, real_lease} = EndpointPool.checkout()

    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__.CapacityPlug, self()},
        ip: {0, 0, 0, 0, 0, 0, 0, 1},
        port: 0
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    busy = %{
      real
      | ip: {0, 0, 0, 0, 0, 0, 0, 1},
        host: "localhost",
        port: port,
        url: "http://[::1]:#{port}"
    }

    :sys.replace_state(
      EndpointPool,
      &%{&1 | uri: %{&1.uri | host: "localhost"}, endpoints: %{busy.ip => busy, real.ip => real}}
    )

    on_exit(fn ->
      EndpointPool.release(real_lease)
      :sys.replace_state(EndpointPool, &%{&1 | uri: original.uri, endpoints: original.endpoints})
    end)

    %{real: real, busy: busy, server: server}
  end

  test "inspection fails over after a real HTTP 503 before running user code" do
    assert {:ok, ["GET /"]} = AppletClient.inspect("export default {'GET /':()=>true}", [])
    assert_receive {:capacity_rejection, "/v1/applet/inspect"}
  end

  test "a refused TCP connection fails over before admission", ctx do
    :ok = GenServer.stop(ctx.server)
    assert {:ok, ["GET /"]} = AppletClient.inspect("export default {'GET /':()=>true}", [])
  end

  test "an Applet preflight 503 fails over to the real WebSocket adapter" do
    {package, context} = package("export default {'POST /':()=>true}")
    {:ok, client, run_id} = AppletClient.start(package, context, timeout_ms: 2_000)
    monitor = Process.monitor(client)
    assert_receive {:capacity_rejection, "/v1/applet/invoke"}

    assert_receive {:applet_runtime, ^run_id, :done, %{"status" => 200, "body" => true}},
                   5_000

    assert_receive {:DOWN, ^monitor, :process, ^client, :normal}, 5_000
  end

  test "a dispatched write capability is not replayed after the worker loses its connection" do
    {package, context} =
      package(
        "export default {'POST /':async()=>{await AnkoleRuntime.db.write('table',{});while(true){}}}"
      )

    {:ok, client, run_id} = AppletClient.start(package, context, timeout_ms: 150)
    monitor = Process.monitor(client)

    assert_receive {:applet_runtime, ^run_id, :call, call_id, "db.write", ["table", %{}]},
                   5_000

    AppletClient.reply(client, call_id, {:ok, %{written: true}})
    assert_receive {:applet_runtime, ^run_id, :done, %{"status" => status}}, 5_000
    assert status in [500, 504]
    assert_receive {:DOWN, ^monitor, :process, ^client, :normal}, 5_000
    refute_receive {:applet_runtime, _, :call, _, "db.write", _}, 200
  end

  test "worker startup consumes the call deadline and cannot dispatch a late write" do
    {package, context} =
      package("""
      await new Promise(resolve => setTimeout(resolve, 200));
      export default {'POST /':()=>AnkoleRuntime.db.write('table', {})}
      """)

    {:ok, client, run_id} = AppletClient.start(package, context, timeout_ms: 80)
    monitor = Process.monitor(client)

    assert_receive {:applet_runtime, ^run_id, :done,
                    %{"status" => 504, "body" => %{"error" => %{"code" => "handler_timeout"}}}},
                   5_000

    assert_receive {:DOWN, ^monitor, :process, ^client, :normal}, 5_000
    refute_receive {:applet_runtime, ^run_id, :call, _, "db.write", _}, 200
  end

  test "preflight, code upload and WebSocket upgrade share the call deadline", ctx do
    for stage <- [:preflight, :code, :upgrade] do
      server = slow_admission(ctx.real, stage)
      {package, context} = package("export default {'POST /':()=>true}")

      try do
        {:ok, client, run_id} = AppletClient.start(package, context, timeout_ms: 100)
        monitor = Process.monitor(client)
        assert_receive {:slow_admission, ^stage}, 500

        assert_receive {:applet_runtime, ^run_id, :done,
                        %{"status" => 504, "body" => %{"error" => %{"code" => "handler_timeout"}}}},
                       500

        assert_receive {:DOWN, ^monitor, :process, ^client, :normal}, 500
        refute_receive {:applet_runtime, ^run_id, :call, _, _, _}
      after
        GenServer.stop(server)
      end
    end
  end

  test "invocation cancellation stops a client stalled in admission", ctx do
    server = slow_admission(ctx.real, :preflight)
    {package, context} = package("export default {'POST /':()=>true}")

    try do
      {:ok, task} =
        Ankole.Repo.with_tenant(Ash.UUIDv7.generate(), fn ->
          Ankole.Pod.Applets.Invocation.start(package, context, [timeout_ms: 30_000], nil)
        end)

      assert_receive {:slow_admission, :preflight}, 500
      Ankole.Pod.Applets.Invocation.cancel(task)
      assert_receive {:DOWN, ref, :process, pid, :normal}, 1_500
      assert ref == task.ref
      assert pid == task.pid
    after
      GenServer.stop(server)
    end
  end

  test "received completion survives a closed transport without replaying its write" do
    {package, context} =
      package("export default {'POST /':()=>AnkoleRuntime.db.write('table', {})}")

    {:ok, client, run_id} = AppletClient.start(package, context, timeout_ms: 5_000)
    monitor = Process.monitor(client)
    assert_receive {:applet_runtime, ^run_id, :call, call_id, "db.write", _}, 5_000
    {:links, links} = Process.info(client, :links)
    [socket] = Enum.filter(links, &is_port/1)

    :erlang.suspend_process(client)

    try do
      reply = Torque.encode!(%{type: "reply", call_id: call_id, value: %{written: true}})
      assert byte_size(reply) < 126

      assert :ok =
               :gen_tcp.send(socket, <<0x81, 0x80 + byte_size(reply), 0, 0, 0, 0, reply::binary>>)

      assert Ankole.Eventually.eventually(fn ->
               {:messages, messages} = Process.info(client, :messages)

               Enum.any?(messages, fn
                 {:tcp, ^socket, bytes} -> :binary.match(bytes, ~s("type":"done")) != :nomatch
                 _ -> false
               end)
             end)

      assert :ok = :gen_tcp.close(socket)
    after
      :erlang.resume_process(client)
    end

    assert_receive {:applet_runtime, ^run_id, :done,
                    %{"status" => 200, "body" => %{"written" => true}}},
                   5_000

    assert_receive {:DOWN, ^monitor, :process, ^client, :normal}, 5_000
    refute_receive {:applet_runtime, ^run_id, :call, _, "db.write", _}, 100
    refute_receive {:applet_runtime, ^run_id, :done, _}, 100
  end

  defp package(source) do
    id = Ash.UUIDv7.generate()
    digest = :crypto.hash(:sha256, source <> "\n[]") |> Base.encode16(case: :lower)

    {%{tenant_id: "test", source: source, env: %{}, sha256: digest},
     %{"method" => "POST", "path" => "/", "applet" => %{"pageId" => id, "revision" => 1}}}
  end

  defp slow_admission(endpoint, stage) do
    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__.SlowAdmissionPlug, {self(), stage}},
        ip: {0, 0, 0, 0, 0, 0, 0, 1},
        port: 0
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    endpoint = %{
      endpoint
      | ip: {0, 0, 0, 0, 0, 0, 0, 1},
        host: "localhost",
        port: port,
        url: "http://[::1]:#{port}"
    }

    :sys.replace_state(EndpointPool, &%{&1 | endpoints: %{endpoint.ip => endpoint}})
    server
  end
end
