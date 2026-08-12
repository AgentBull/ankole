defmodule Ankole.Ecto.CronDeliveryTargetsMigrationTest do
  use Ankole.DataCase, async: false

  alias Ankole.Repo

  @migration Ankole.Repo.Migrations.MigrateCronDeliveryTargets

  unless Code.ensure_loaded?(@migration) do
    Code.require_file(
      Path.expand(
        "../../../priv/repo/migrations/20260812060345_migrate_cron_delivery_targets.exs",
        __DIR__
      )
    )
  end

  setup do
    schema = "cron_delivery_targets_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE SCHEMA #{schema}")
    Repo.query!("SET LOCAL search_path TO #{schema}")

    Repo.query!("""
    CREATE TABLE actor_cron_schedules (
      binding_name text NOT NULL,
      delivery jsonb NOT NULL
    )
    """)

    Repo.query!("""
    CREATE TABLE actor_scheduled_events (
      kind text NOT NULL,
      status text NOT NULL,
      binding_name text NOT NULL,
      wake_payload jsonb NOT NULL
    )
    """)

    :ok
  end

  test "migrates active schedule state without rewriting fired history" do
    legacy = %{
      "signal_channel_id" => "lark:primary",
      "provider_thread_id" => "thread-primary",
      "quiet_success" => true
    }

    Repo.query!(
      "INSERT INTO actor_cron_schedules (binding_name, delivery) VALUES ($1, $2)",
      ["lark-main", legacy]
    )

    for status <- ["scheduled", "fired"] do
      Repo.query!(
        """
        INSERT INTO actor_scheduled_events (kind, status, binding_name, wake_payload)
        VALUES ('cron_fire', $1, $2, $3)
        """,
        [status, "lark-main", %{"delivery" => legacy, "payload" => %{"task" => "report"}}]
      )
    end

    run_up()

    assert [[delivery]] = Repo.query!("SELECT delivery FROM actor_cron_schedules").rows

    assert delivery == %{
             "quiet_success" => true,
             "targets" => [
               %{
                 "binding_name" => "lark-main",
                 "signal_channel_id" => "lark:primary",
                 "provider_thread_id" => "thread-primary"
               }
             ]
           }

    assert [["scheduled", pending], ["fired", fired]] =
             Repo.query!("""
             SELECT status, wake_payload->'delivery'
             FROM actor_scheduled_events
             ORDER BY status DESC
             """).rows

    assert pending == delivery
    assert fired == legacy
  end

  test "downgrades a one-target configuration without losing options" do
    canonical = %{
      "quiet_success" => false,
      "targets" => [
        %{
          "binding_name" => "lark-main",
          "signal_channel_id" => "lark:primary"
        }
      ]
    }

    Repo.query!(
      "INSERT INTO actor_cron_schedules (binding_name, delivery) VALUES ($1, $2)",
      ["lark-main", canonical]
    )

    run_down()

    assert [[delivery]] = Repo.query!("SELECT delivery FROM actor_cron_schedules").rows

    assert delivery == %{
             "quiet_success" => false,
             "signal_channel_id" => "lark:primary"
           }
  end

  test "refuses a lossy downgrade when a schedule has multiple targets" do
    delivery = %{
      "targets" => [
        %{"binding_name" => "lark-main", "signal_channel_id" => "lark:primary"},
        %{"binding_name" => "lark-main", "signal_channel_id" => "lark:secondary"}
      ]
    }

    Repo.query!(
      "INSERT INTO actor_cron_schedules (binding_name, delivery) VALUES ($1, $2)",
      ["lark-main", delivery]
    )

    assert_raise Postgrex.Error, ~r/cannot be downgraded/, fn -> run_down() end
  end

  defp run_up, do: Enum.each(@migration.up_sqls(), &Repo.query!/1)
  defp run_down, do: Enum.each(@migration.down_sqls(), &Repo.query!/1)
end
