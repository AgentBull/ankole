defmodule Ankole.Plugins.LarkAdapter.CardKitWriteLimiterTest do
  use ExUnit.Case, async: true

  alias Ankole.Plugins.LarkAdapter.CardKit.WriteLimiter

  test "spaces writes for one application without blocking another application" do
    interval_ms = 200
    limiter = start_limiter(interval_ms)
    first_send_at = System.monotonic_time(:millisecond)

    assert :ok = WriteLimiter.wait("cli_a", limiter)

    queued =
      for _index <- 1..2 do
        Task.async(fn ->
          :ok = WriteLimiter.wait("cli_a", limiter)
          System.monotonic_time(:millisecond)
        end)
      end

    assert :ok = WriteLimiter.wait("cli_b", limiter)
    assert Enum.all?(queued, &(Task.yield(&1, 50) == nil))

    [second_send_at, third_send_at] =
      queued
      |> Enum.map(&Task.await(&1, 1_000))
      |> Enum.sort()

    assert second_send_at - first_send_at >= interval_ms - 20
    assert third_send_at - second_send_at >= interval_ms - 20
  end

  defp start_limiter(interval_ms) do
    start_supervised!({WriteLimiter, name: nil, interval_ms: interval_ms})
  end
end
