defmodule FeishuOpenAPI.WS.ClientTest do
  use ExUnit.Case, async: false

  alias FeishuOpenAPI.Client, as: APIClient
  alias FeishuOpenAPI.Event.Dispatcher
  alias FeishuOpenAPI.WS.{Client, Frame}

  test "late dispatch results after disconnect are ignored instead of crashing the client" do
    client =
      APIClient.new("cli_ws_#{System.unique_integer([:positive])}", "secret",
        req_options: [
          plug: fn conn ->
            Req.Test.json(conn, %{"code" => 99_999, "msg" => "endpoint unavailable"})
          end
        ]
      )

    {:ok, pid} =
      Client.start_link(client: client, dispatcher: Dispatcher.new(), auto_reconnect: true)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    wait_until(fn ->
      state = :sys.get_state(pid)
      Client.status(pid) == :disconnected and not is_nil(state.reconnect_timer)
    end)

    ref = make_ref()

    frame = %Frame{
      seq_id: 1,
      log_id: 2,
      service: 3,
      method: 1,
      headers: [{"type", "event"}]
    }

    :sys.replace_state(pid, fn state ->
      %{
        state
        | conn: nil,
          websocket: nil,
          request_ref: nil,
          dispatch_tasks: %{
            ref => {frame, "im.message.receive_v1", System.monotonic_time(:millisecond)}
          }
      }
    end)

    send(pid, {ref, {:ok, :handled}})
    Process.sleep(100)

    assert Process.alive?(pid)
    assert :sys.get_state(pid).dispatch_tasks == %{}
  end

  test "start_link validates required option types" do
    client = APIClient.new("cli_ws_bad", "secret")

    assert_raise RuntimeError, ~r/:dispatcher/, fn ->
      start_supervised!({Client, client: client, dispatcher: :bad})
    end
  end

  test "endpoint discovery accepts a URL-only response without ClientConfig" do
    previous = Process.flag(:trap_exit, true)

    try do
      client =
        APIClient.new("cli_ws_url_only", "secret",
          req_options: [
            plug: fn conn ->
              Req.Test.json(conn, %{
                "code" => 0,
                "data" => %{"URL" => "http://endpoint-only.example.test/ws"}
              })
            end
          ]
        )

      {:ok, pid} =
        Client.start_link(client: client, dispatcher: Dispatcher.new(), auto_reconnect: false)

      assert_receive {:EXIT, ^pid, {:shutdown, {:bad_scheme, "http"}}}, :timer.seconds(1)
    after
      Process.flag(:trap_exit, previous)
    end
  end

  defp wait_until(fun, attempts \\ 50)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0) do
    flunk("condition was not met before timeout")
  end
end
