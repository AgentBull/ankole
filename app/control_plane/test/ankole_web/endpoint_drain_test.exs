defmodule AnkoleWeb.EndpointDrainTest do
  use AnkoleWeb.ConnCase, async: true

  alias AnkoleWeb.EndpointDrain

  test "health and liveness probes succeed on Pod-IP Host headers without hitting RequestHost" do
    for {method, path, expected_body} <- [
          {:get, "/_internal/health", ~s({"status":"ok"})},
          {:head, "/_internal/health", ""},
          {:get, "/_internal/live", ~s({"status":"ok"})},
          {:head, "/_internal/live", ""}
        ] do
      conn =
        %{Phoenix.ConnTest.build_conn(method, path) | host: "10.244.0.15", port: 4000}
        |> AnkoleWeb.Endpoint.call(AnkoleWeb.Endpoint.init([]))

      assert conn.halted
      assert conn.status == 200
      assert conn.resp_body == expected_body
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"
    end
  end

  test "lifecycle transitions from starting to ready, then flips to draining and delays shutdown" do
    state_key = {__MODULE__, make_ref()}
    on_exit(fn -> :persistent_term.erase(state_key) end)

    assert EndpointDrain.status(state_key) == :starting
    refute EndpointDrain.ready?(state_key)
    refute EndpointDrain.draining?(state_key)

    starting_conn =
      Phoenix.ConnTest.build_conn(:get, "/_internal/health")
      |> EndpointDrain.call_health_plug(state_key)

    assert starting_conn.status == 503
    assert starting_conn.resp_body == ~s({"status":"starting"})

    {:ok, pid} =
      EndpointDrain.start_link(
        name: nil,
        state_key: state_key,
        drain_delay_ms: 80
      )

    Process.unlink(pid)

    assert EndpointDrain.status(state_key) == :ready
    assert EndpointDrain.ready?(state_key)
    refute EndpointDrain.draining?(state_key)

    ready_conn =
      Phoenix.ConnTest.build_conn(:get, "/_internal/health")
      |> EndpointDrain.call_health_plug(state_key)

    assert ready_conn.status == 200
    assert ready_conn.resp_body == ~s({"status":"ok"})

    stop_started_at = System.monotonic_time(:millisecond)
    stop_task = Task.async(fn -> GenServer.stop(pid, :shutdown) end)

    wait_until(fn -> EndpointDrain.draining?(state_key) end)

    draining_conn =
      Phoenix.ConnTest.build_conn(:get, "/_internal/health")
      |> EndpointDrain.call_health_plug(state_key)

    assert draining_conn.status == 503
    assert draining_conn.resp_body == ~s({"status":"draining"})

    live_conn =
      Phoenix.ConnTest.build_conn(:get, "/_internal/live")
      |> EndpointDrain.call_health_plug(state_key)

    assert live_conn.status == 200
    assert live_conn.resp_body == ~s({"status":"ok"})

    assert :ok = Task.await(stop_task, 2_000)
    elapsed_ms = System.monotonic_time(:millisecond) - stop_started_at
    assert elapsed_ms >= 75
  end

  defp wait_until(predicate, attempts \\ 40)

  defp wait_until(predicate, 0) do
    assert predicate.()
  end

  defp wait_until(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(5)
      wait_until(predicate, attempts - 1)
    end
  end
end
