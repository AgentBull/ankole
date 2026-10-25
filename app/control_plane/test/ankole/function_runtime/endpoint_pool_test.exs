defmodule Ankole.FunctionRuntime.EndpointPoolTest do
  use ExUnit.Case, async: false
  alias Ankole.FunctionRuntime.EndpointPool

  setup do
    original = :sys.get_state(EndpointPool)
    template = original.endpoints |> Map.values() |> hd()
    left = endpoint(template, template.ip)
    right = endpoint(template, {127, 0, 0, 11})
    :sys.replace_state(EndpointPool, &%{&1 | endpoints: %{left.ip => left, right.ip => right}})
    on_exit(fn -> :sys.replace_state(EndpointPool, &%{&1 | endpoints: original.endpoints}) end)
    %{left: left, right: right}
  end

  test "leases choose the least occupied replica and release exactly once", ctx do
    assert {:ok, _, right_lease} = EndpointPool.checkout([ctx.left.ip])
    assert {:ok, endpoint, lease} = EndpointPool.checkout()
    assert endpoint.ip == ctx.left.ip
    assert :sys.get_state(EndpointPool).leases[lease] == ctx.left.ip
    EndpointPool.release(lease)
    EndpointPool.release(lease)
    refute Map.has_key?(:sys.get_state(EndpointPool).leases, lease)
    assert {:ok, endpoint, next_lease} = EndpointPool.checkout()
    assert endpoint.ip == ctx.left.ip
    EndpointPool.release(right_lease)
    EndpointPool.release(next_lease)
  end

  test "an exited lease owner releases occupancy", ctx do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, _endpoint, lease} = EndpointPool.checkout([ctx.right.ip])
        send(parent, {:leased, lease})
      end)

    monitor = Process.monitor(owner)
    assert_receive {:leased, lease}
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}

    assert Ankole.Eventually.eventually(fn ->
             not Map.has_key?(:sys.get_state(EndpointPool).leases, lease)
           end)
  end

  test "an unavailable replica is cooled and a DNS refresh removes departed replicas", ctx do
    EndpointPool.unavailable(ctx.left)
    send(EndpointPool, :refresh_now)
    state = :sys.get_state(EndpointPool)
    assert state.endpoints[ctx.left.ip].cooldown > System.monotonic_time(:millisecond)
    refute Map.has_key?(state.endpoints, ctx.right.ip)
    assert {:error, :function_runtime_unavailable} = EndpointPool.checkout()
    Process.sleep(2_100)
    assert {:ok, endpoint, lease} = EndpointPool.checkout()
    assert endpoint.ip == ctx.left.ip
    EndpointPool.release(lease)
  end

  defp endpoint(template, ip),
    do: %{
      template
      | ip: ip,
        cooldown: System.monotonic_time(:millisecond) - 1
    }
end
