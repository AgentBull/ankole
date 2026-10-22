defmodule Ankole.Kernel.AppletRuntimeTest do
  use ExUnit.Case, async: false

  alias Ankole.Kernel.AppletRuntime

  setup_all do
    # The control plane loads these NIF libraries before Endpoint is ready.
    # Load the same dependencies here without creating an Applet isolate.
    Code.ensure_loaded!(Torque.Native)
    Code.ensure_loaded!(Ankole.Kernel)
    :ok
  end

  @context %{
    "method" => "POST",
    "path" => "/orders/a%2Fb",
    "query" => %{},
    "principal" => %{"uid" => "human-1", "kind" => "human"},
    "applet" => %{"pageId" => "page-1", "revision" => 2},
    "timezone" => "Asia/Singapore"
  }

  test "inspection validates the complete bundle without running handlers" do
    assert {:ok, ["POST /orders/:id"]} =
             AppletRuntime.inspect(
               "export default {'POST /orders/:id':()=>{throw Error('not run')}}"
             )

    assert {:error, %{"status" => 400, "code" => "invalid_applet_routes"}} =
             AppletRuntime.inspect("export default {'GET /':()=>import('file:///etc/passwd')}")
  end

  test "a native invocation retains state while the caller performs a capability" do
    source =
      "let count=0; export default {'POST /orders/:id': async ({params}) => {count++; console.info('writing',params.id); const result=await AnkoleRuntime.db.write('table',{count});return {count,result,params}}}"

    assert {:ok, handle, run_id} = AppletRuntime.start(source, @context, timeout_ms: 2_000)
    assert_receive {:applet_runtime, ^run_id, :call, id, "db.write", arguments}, 2_000
    assert {:ok, ["table", %{"count" => 1}]} = Torque.decode(arguments)
    assert :ok = AppletRuntime.reply(handle, id, {:ok, %{"written" => true}})
    assert_receive {:applet_runtime, ^run_id, :done, json}, 2_000

    assert {:ok,
            %{
              "status" => 200,
              "body" => %{
                "count" => 1,
                "params" => %{"id" => "a/b"},
                "result" => %{"written" => true}
              },
              "logs" => [%{"message" => "writing a/b"}]
            }} = Torque.decode(json)
  end

  test "timeouts cover waiting for a capability and do not block BEAM" do
    assert {:ok, handle, run_id} =
             AppletRuntime.start(
               "export default {'POST /orders/:id':()=>AnkoleRuntime.db.query('t',{})}",
               @context,
               timeout_ms: 50
             )

    assert_receive {:applet_runtime, ^run_id, :call, id, "db.query", _}, 2_000
    assert_receive {:applet_runtime, ^run_id, :done, json}, 2_000

    assert {:ok, %{"status" => 504, "body" => %{"error" => %{"code" => "handler_timeout"}}}} =
             Torque.decode(json)

    assert {:error, :invocation_ended} = AppletRuntime.reply(handle, id, {:ok, %{}})
  end

  test "explicit cancellation interrupts a running native isolate" do
    assert {:ok, handle, run_id} =
             AppletRuntime.start(
               "export default {'POST /orders/:id':()=>{while(true){}}}",
               @context,
               timeout_ms: 2_000
             )

    assert :ok = AppletRuntime.cancel(handle)
    assert_receive {:applet_runtime, ^run_id, :done, json}, 2_000

    assert {:ok, %{"status" => 499, "body" => %{"error" => %{"code" => "handler_cancelled"}}}} =
             Torque.decode(json)
  end

  test "owner exit cancels a capability wait even if another process keeps the resource" do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        {:ok, handle, run_id} =
          AppletRuntime.start(
            "export default {'POST /orders/:id':()=>AnkoleRuntime.db.query('t',{})}",
            @context,
            timeout_ms: 10_000
          )

        receive do
          {:applet_runtime, ^run_id, :call, id, "db.query", _} ->
            send(parent, {:waiting, handle, id})

          {:applet_runtime, ^run_id, :done, json} ->
            raise "Invocation ended before its capability request: #{json}"
        end
      end)

    try do
      assert_receive {:waiting, handle, id}, 2_000
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2_000
      # The owner monitor signals native termination asynchronously.
      Process.sleep(100)
      assert {:error, :invocation_ended} = AppletRuntime.reply(handle, id, {:ok, %{}})
    after
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      Process.demonitor(monitor, [:flush])
    end
  end

  test "fifth concurrent invocation returns synchronous applet_busy without panicking on BEAM scheduler" do
    source = "export default {'POST /orders/:id':()=>AnkoleRuntime.db.query('t',{})}"

    active =
      for _ <- 1..4 do
        {:ok, handle, run_id} = AppletRuntime.start(source, @context, timeout_ms: 10_000)
        assert_receive {:applet_runtime, ^run_id, :call, _id, "db.query", _}, 2_000
        {handle, run_id}
      end

    try do
      assert {:error,
              {:applet_busy,
               %{
                 "status" => 503,
                 "body" => %{
                   "error" => %{
                     "code" => "applet_busy",
                     "message" => "Applet runtime is at capacity"
                   }
                 }
               }}} = AppletRuntime.start(source, @context, timeout_ms: 1_000)

      assert {:error,
              %{
                "status" => 503,
                "code" => "applet_busy",
                "message" => "Applet runtime is at capacity"
              }} = AppletRuntime.inspect("export default {'GET /':()=>1}")
    after
      Enum.each(active, fn {handle, run_id} ->
        AppletRuntime.cancel(handle)
        assert_receive {:applet_runtime, ^run_id, :done, _}, 2_000
      end)
    end
  end
end
