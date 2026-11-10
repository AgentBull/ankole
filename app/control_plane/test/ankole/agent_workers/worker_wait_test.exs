defmodule Ankole.AgentWorkers.WorkerWaitTest do
  use ExUnit.Case, async: true

  alias Ankole.AgentWorkers
  alias Ankole.AgentWorkers.AgentWorker

  @now ~U[2026-10-22 00:00:00.000000Z]
  @timeout_ms 60_000
  @expired DateTime.add(@now, -@timeout_ms, :millisecond)
  @unexpired DateTime.add(@expired, 1, :millisecond)

  @unavailable_states [:absent, :starting, :stale, :paused, :draining, :deleting, nil]

  # All unavailable Workers use the same clock. Test each state once, then
  # use a starting Worker for the remaining timing and work capacity cases.
  for {states, label, capacity_available?, started_at, expected} <- [
        {@unavailable_states, "starts on the first eligible probe", true, nil, {:wait, @now}},
        {[:starting], "keeps an unexpired clock", true, @unexpired, {:wait, @unexpired}},
        {[:starting], "expires at the exact deadline", true, @expired, {:timed_out, @expired}},
        {[:starting], "does not start at capacity", false, nil, {:wait, nil}},
        {[:starting], "keeps an unexpired clock at capacity", false, @unexpired,
         {:wait, @unexpired}},
        {[:starting], "does not reset or expire at capacity", false, @expired, {:wait, @expired}}
      ],
      state <- states do
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

  for {capacity_available?, available_slots, started_at} <- [
        {true, 0, nil},
        {true, 1, @unexpired},
        {true, 0, @expired},
        {false, 1, nil},
        {false, 0, @unexpired},
        {false, 1, @expired}
      ] do
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
