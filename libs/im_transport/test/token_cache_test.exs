defmodule IMTransport.TokenCacheTest do
  use ExUnit.Case, async: true

  alias IMTransport.TokenCache

  test "lookup returns a live row and deletes an expired row" do
    table = :im_transport_token_cache_test
    TokenCache.ensure_table(table)
    key = {:sample, System.unique_integer([:positive])}

    assert TokenCache.lookup(table, key) == :miss

    assert {:ok, "token", expires_at} = TokenCache.store(table, key, "token", 7200)

    assert expires_at <=
             System.monotonic_time(:millisecond) + :timer.seconds(7200) - :timer.minutes(3)

    assert TokenCache.lookup(table, key) == {:ok, "token"}

    :ets.insert(table, {key, "stale", System.monotonic_time(:millisecond) - 1})
    assert TokenCache.lookup(table, key) == :miss
    assert :ets.lookup(table, key) == []
  end
end
