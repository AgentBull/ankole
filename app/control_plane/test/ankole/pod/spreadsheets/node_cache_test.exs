defmodule Ankole.Pod.Spreadsheets.NodeCacheTest do
  use ExUnit.Case, async: false
  alias Ankole.Pod.Spreadsheets.NodeCache

  test "a read records its time only when the last record is older than 30 seconds" do
    key = {Ecto.UUID.generate(), Ecto.UUID.generate()}
    on_exit(fn -> :ets.delete(NodeCache, key) end)

    assert :ok = NodeCache.put(key, 1, :document)
    [{^key, 1, :document, written}] = :ets.lookup(NodeCache, key)

    assert {:ok, 1, :document} = NodeCache.fetch(key)
    assert [{^key, 1, :document, ^written}] = :ets.lookup(NodeCache, key)

    stale = written - :timer.seconds(31)
    :ets.update_element(NodeCache, key, {4, stale})
    assert {:ok, 1, :document} = NodeCache.fetch(key)
    assert [{^key, 1, :document, touched}] = :ets.lookup(NodeCache, key)
    assert touched > stale
  end
end
