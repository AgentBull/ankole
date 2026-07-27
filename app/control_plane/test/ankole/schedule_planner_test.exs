defmodule Ankole.Schedule.PlannerTest do
  use ExUnit.Case, async: true

  alias Ankole.Schedule.Planner

  @timezone "America/New_York"

  test "normalizes five and six field Crontab expressions" do
    assert {:ok, five_field, @timezone} =
             Planner.normalize_schedule_json(
               %{
                 "kind" => "cron",
                 "expression" => "  0   9  * *  MON-FRI ",
                 "timezone" => @timezone
               },
               %{},
               []
             )

    assert five_field["expression"] == "0 9 * * MON-FRI"

    assert {:ok, six_field, @timezone} =
             Planner.normalize_schedule_json(
               %{
                 "kind" => "cron",
                 "expression" => "15,45 * * * * *",
                 "timezone" => @timezone
               },
               %{},
               []
             )

    assert six_field["expression"] == "15,45 * * * * *"

    assert {:error, :invalid_cron_expression} =
             Planner.normalize_schedule_json(
               %{
                 "kind" => "cron",
                 "expression" => "0 15 9 * * * 2026",
                 "timezone" => @timezone
               },
               %{},
               []
             )
  end

  test "keeps wall-clock cron time across the spring DST transition" do
    assert_next_fire(
      "0 9 * * *",
      ~U[2026-03-07 14:00:00Z],
      ~U[2026-03-08 13:00:00Z]
    )
  end

  test "moves cron times in a DST gap to the first post-gap instant" do
    assert_next_fire(
      "30 2 * * *",
      ~U[2026-03-08 06:00:00Z],
      ~U[2026-03-08 07:00:00Z]
    )
  end

  test "uses only the first occurrence in a DST fold" do
    assert_next_fire(
      "30 1 * * *",
      ~U[2026-11-01 04:00:00Z],
      ~U[2026-11-01 05:30:00Z]
    )

    assert_next_fire(
      "30 1 * * *",
      ~U[2026-11-01 05:45:00Z],
      ~U[2026-11-02 06:30:00Z]
    )

    assert_next_fire(
      "30 1 * * *",
      ~U[2026-11-01 06:15:00Z],
      ~U[2026-11-02 06:30:00Z]
    )
  end

  test "supports second precision without losing strict next-fire ordering" do
    assert_next_fire(
      "15,45 * * * * *",
      ~U[2026-07-18 00:00:15Z],
      ~U[2026-07-18 00:00:45Z]
    )
  end

  test "preserves day-of-month and day-of-week AND semantics" do
    schedule = %{
      "kind" => "cron",
      "expression" => "0 9 15 * MON"
    }

    assert {:ok, actual} =
             Planner.next_fire_after(schedule, "Etc/UTC", ~U[2026-01-01 00:00:00Z])

    assert DateTime.compare(actual, ~U[2026-06-15 09:00:00Z]) == :eq
  end

  defp assert_next_fire(expression, after_at, expected) do
    schedule = %{"kind" => "cron", "expression" => expression}

    assert {:ok, actual} = Planner.next_fire_after(schedule, @timezone, after_at)
    assert DateTime.compare(actual, expected) == :eq
  end
end
