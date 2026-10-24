defmodule Ankole.Authn.RateLimiterTest do
  use ExUnit.Case, async: false
  alias Ankole.Authn.RateLimiter

  setup do
    RateLimiter.reset_for_test()
    on_exit(&RateLimiter.reset_for_test/0)
  end

  test "a rejected source does not consume another person's or the channel's quota" do
    blocked = {"source", "blocked", 1, 60}
    victim = {"email", "victim@example.org", 1, 60}
    channel = {"channel", "smtp", 1, 60}
    assert :ok = RateLimiter.take([blocked])
    assert {:error, {:rate_limited, _}} = RateLimiter.take([victim, blocked, channel])
    assert :ok = RateLimiter.take([victim, channel])
  end

  test "concurrent requests consume all windows together" do
    results =
      1..50
      |> Task.async_stream(fn _ -> RateLimiter.take([{"source", "shared", 10, 600}]) end,
        max_concurrency: 50
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == :ok)) == 10
    assert Enum.count(results, &match?({:error, {:rate_limited, _}}, &1)) == 40
  end

  test "a full table permits verification and existing windows, and reclaims expired keys" do
    known = [{"source", "known", 10, 600}]
    assert :ok = RateLimiter.take(known)
    expires = System.monotonic_time(:second) + 600
    :ets.insert(RateLimiter, Enum.map(1..99_999, &{{:occupied, &1}, 1, expires}))
    assert :ok = RateLimiter.check(known)
    assert :ok = RateLimiter.check([{"failure", "new", 1, 600}])
    assert :ok = RateLimiter.take(known)
    assert {:error, {:rate_limited, _}} = RateLimiter.take([{"source", "new", 1, 600}])
    :ets.insert(RateLimiter, {{:occupied, 1}, 1, expires - 601})
    assert :ok = RateLimiter.take([{"source", "new", 1, 600}])
    assert :ets.info(RateLimiter, :size) == 100_000
  end
end
