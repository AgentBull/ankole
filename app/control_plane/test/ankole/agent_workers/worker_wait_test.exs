defmodule Ankole.AgentWorkers.WorkerWaitTest do
  use ExUnit.Case, async: true

  alias Ankole.AgentWorkers
  alias Ankole.AgentWorkers.AgentWorker

  @now ~U[2026-10-22 00:00:00.000000Z]
  @timeout_ms 60_000
  @expired DateTime.add(@now, -@timeout_ms, :millisecond)
  @unexpired DateTime.add(@expired, 1, :millisecond)

  for state <- [:absent, :starting, :stale, :paused, :draining, :deleting, nil],
      {label, capacity_available?, started_at, expected} <- [
        {"starts on the first eligible probe", true, nil, {:wait, @now}},
        {"keeps an unexpired clock", true, @unexpired, {:wait, @unexpired}},
        {"expires at the exact deadline", true, @expired, {:timed_out, @expired}},
        {"does not start at capacity", false, nil, {:wait, nil}},
        {"keeps an unexpired clock at capacity", false, @unexpired, {:wait, @unexpired}},
        {"does not reset or expire at capacity", false, @expired, {:wait, @expired}}
      ] do
    test "#{inspect(state)} #{label}" do
      worker = if unquote(state), do: %AgentWorker{state: unquote(state)}

      assert AgentWorkers.wait_status(
               worker,
               unquote(capacity_available?),
               unquote(Macro.escape(started_at)),
               @now,
               @timeout_ms
             ) == unquote(Macro.escape(expected))
    end
  end

  for capacity_available? <- [true, false],
      available_slots <- [0, 1],
      started_at <- [nil, @unexpired, @expired] do
    test "ready clears #{inspect(started_at)} with work capacity #{capacity_available?} and #{available_slots} slots" do
      worker = %AgentWorker{
        state: :ready,
        capacity: %{"available_slots" => unquote(available_slots)}
      }

      assert AgentWorkers.wait_status(
               worker,
               unquote(capacity_available?),
               unquote(Macro.escape(started_at)),
               @now,
               @timeout_ms
             ) == {:ready, nil}
    end
  end
end
