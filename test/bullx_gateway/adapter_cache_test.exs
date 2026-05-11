defmodule BullXGateway.AdapterCacheTest do
  use ExUnit.Case, async: true

  alias BullXGateway.AdapterCache

  test "stores namespaced values until their ttl expires" do
    table = AdapterCache.new(__MODULE__)

    assert :ok = AdapterCache.put(table, :direct_command_result, "evt-1", :sent, 10_000)
    assert {:ok, :sent} = AdapterCache.fetch(table, :direct_command_result, "evt-1")
    assert :error = AdapterCache.fetch(table, :direct_command_result, "missing")
  end

  test "deletes expired entries on fetch" do
    table = AdapterCache.new(__MODULE__)

    assert :ok = AdapterCache.put(table, :direct_command_result, "evt-1", :sent, 0)
    Process.sleep(2)

    assert :error = AdapterCache.fetch(table, :direct_command_result, "evt-1")
    assert [] = :ets.lookup(table, {:direct_command_result, "evt-1"})
  end
end
