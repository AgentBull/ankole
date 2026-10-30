defmodule Ankole.Sessions.RetryLadderTest do
  @moduledoc """
  Exhaustive production check for the retry ladder.

  `tools/formal/lean/RetryLadder.lean` proves the ladder policy bounds and
  saturation. `delay_seconds/3` clamps its attempt to `attempt - 1` in
  `0..length - 1`, so every distinct behaviour is reached within `-3..10`;
  `1000` checks the saturation range.
  """

  use ExUnit.Case, async: true

  alias Ankole.Sessions.TurnErrorClassifier

  @attempts Enum.to_list(-3..10) ++ [100, 1_000]

  @conversation_execution [5, 10, 20, 40, 80, 120]
  @conversation_capacity [30, 120, 300, 750]
  @job_execution [60, 600, 1_800, 3_600, 7_200]
  @job_infrastructure [15, 30, 60, 120, 300]

  test "conversation execution delay clamps and saturates at 120s" do
    for attempt <- @attempts do
      delay = TurnErrorClassifier.delay_seconds(:conversation, attempt, :execution)
      assert delay == Enum.at(@conversation_execution, clamp(attempt, 5))
      assert delay >= 5 and delay <= 120
    end
  end

  test "conversation capacity delay saturates at 750s" do
    for attempt <- @attempts do
      delay = TurnErrorClassifier.delay_seconds(:conversation, attempt, :provider_capacity)
      assert delay == Enum.at(@conversation_capacity, clamp(attempt, 3))
      assert delay >= 30 and delay <= 750
    end
  end

  test "job execution delay saturates at 7200s" do
    for attempt <- @attempts do
      delay = TurnErrorClassifier.delay_seconds(:job, attempt, :execution)
      assert delay == Enum.at(@job_execution, clamp(attempt, 4))
      assert delay >= 60 and delay <= 7_200
    end
  end

  test "job infrastructure delay saturates at 300s" do
    for attempt <- @attempts do
      delay = TurnErrorClassifier.delay_seconds(:job, attempt, :infrastructure)
      assert delay == Enum.at(@job_infrastructure, clamp(attempt, 4))
      assert delay >= 15 and delay <= 300
    end
  end

  test "every ladder is non-decreasing across its whole behavioural range" do
    for {scope, cls} <- [
          {:conversation, :execution},
          {:conversation, :provider_capacity},
          {:job, :execution},
          {:job, :infrastructure}
        ] do
      delays =
        Enum.map(-3..10, fn attempt ->
          TurnErrorClassifier.delay_seconds(scope, attempt, cls)
        end)

      assert delays == Enum.sort(delays)
    end
  end

  # The production function clamps `attempt - 1` into `0..max_index`.
  defp clamp(attempt, max_index), do: min(max(attempt - 1, 0), max_index)
end
