defmodule Ankole.Ecto.PauseInvalidDirectCronSchedulesMigrationTest do
  use Ankole.DataCase, async: false

  alias Ankole.Repo

  @migration Ankole.Repo.Migrations.PauseInvalidDirectCronSchedules

  unless Code.ensure_loaded?(@migration) do
    Code.require_file(
      Path.expand(
        "../../../priv/repo/migrations/20260812145614_pause_invalid_direct_cron_schedules.exs",
        __DIR__
      )
    )
  end

  setup do
    schema = "invalid_direct_cron_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE SCHEMA #{schema}")
    Repo.query!("SET LOCAL search_path TO #{schema}")

    Repo.query!("""
    CREATE TABLE actor_cron_schedules (
      id text PRIMARY KEY,
      status text NOT NULL,
      next_fire_at timestamptz,
      payload jsonb NOT NULL,
      automation_job_id bigint,
      updated_at timestamptz NOT NULL
    )
    """)

    Repo.query!("""
    CREATE TABLE actor_scheduled_events (
      id text PRIMARY KEY,
      cron_schedule_id text NOT NULL,
      kind text NOT NULL,
      status text NOT NULL,
      cancelled_at timestamptz,
      last_fire_error jsonb NOT NULL,
      updated_at timestamptz NOT NULL
    )
    """)

    :ok
  end

  test "pauses unsafe direct schedules and cancels only their live fires" do
    now = DateTime.utc_now(:microsecond)
    next_fire_at = DateTime.add(now, 1, :hour)

    schedules = [
      ["missing", "active", next_fire_at, %{}, nil, now],
      ["blank", "paused", nil, %{"task" => "\n\t"}, nil, now],
      ["valid", "active", next_fire_at, %{"task" => "Prepare the report."}, nil, now],
      ["automation", "active", next_fire_at, %{}, 42, now]
    ]

    Enum.each(schedules, fn values ->
      Repo.query!(
        """
        INSERT INTO actor_cron_schedules
          (id, status, next_fire_at, payload, automation_job_id, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6)
        """,
        values
      )
    end)

    events = [
      ["missing-live", "missing", "scheduled", now],
      ["blank-live", "blank", "firing", now],
      ["valid-live", "valid", "scheduled", now],
      ["automation-live", "automation", "scheduled", now],
      ["missing-history", "missing", "fired", now]
    ]

    Enum.each(events, fn [id, schedule_id, status, updated_at] ->
      Repo.query!(
        """
        INSERT INTO actor_scheduled_events
          (id, cron_schedule_id, kind, status, last_fire_error, updated_at)
        VALUES ($1, $2, 'cron_fire', $3, '{}'::jsonb, $4)
        """,
        [id, schedule_id, status, updated_at]
      )
    end)

    Enum.each(@migration.up_sqls(), &Repo.query!/1)

    assert [
             ["automation", "active", false],
             ["blank", "paused", true],
             ["missing", "paused", true],
             ["valid", "active", false]
           ] =
             Repo.query!("""
             SELECT id, status, next_fire_at IS NULL
             FROM actor_cron_schedules
             ORDER BY id
             """).rows

    assert [
             ["automation-live", "scheduled", false, nil],
             ["blank-live", "cancelled", true, "cron_task_required"],
             ["missing-history", "fired", false, nil],
             ["missing-live", "cancelled", true, "cron_task_required"],
             ["valid-live", "scheduled", false, nil]
           ] =
             Repo.query!("""
             SELECT id, status, cancelled_at IS NOT NULL, last_fire_error->>'reason'
             FROM actor_scheduled_events
             ORDER BY id
             """).rows
  end
end
