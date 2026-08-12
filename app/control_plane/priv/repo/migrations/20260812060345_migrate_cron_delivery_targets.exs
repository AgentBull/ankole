defmodule Ankole.Repo.Migrations.MigrateCronDeliveryTargets do
  use Ecto.Migration

  def up do
    Enum.each(up_sqls(), &execute/1)
  end

  def down do
    Enum.each(down_sqls(), &execute/1)
  end

  @doc false
  def up_sqls do
    [
      """
      UPDATE actor_cron_schedules
      SET delivery =
        (delivery - 'signal_channel_id' - 'provider_thread_id') ||
        jsonb_build_object(
          'targets',
          jsonb_build_array(
            jsonb_strip_nulls(
              jsonb_build_object(
                'binding_name', binding_name,
                'signal_channel_id', delivery->'signal_channel_id',
                'provider_thread_id', delivery->'provider_thread_id'
              )
            )
          )
        )
      WHERE jsonb_typeof(delivery) = 'object'
        AND delivery ? 'signal_channel_id'
        AND NOT delivery ? 'targets'
      """,
      """
      UPDATE actor_scheduled_events
      SET wake_payload = jsonb_set(
        wake_payload,
        '{delivery}',
        ((wake_payload->'delivery') - 'signal_channel_id' - 'provider_thread_id') ||
        jsonb_build_object(
          'targets',
          jsonb_build_array(
            jsonb_strip_nulls(
              jsonb_build_object(
                'binding_name', binding_name,
                'signal_channel_id', wake_payload#>'{delivery,signal_channel_id}',
                'provider_thread_id', wake_payload#>'{delivery,provider_thread_id}'
              )
            )
          )
        ),
        true
      )
      WHERE kind = 'cron_fire'
        AND status IN ('scheduled', 'firing')
        AND jsonb_typeof(wake_payload->'delivery') = 'object'
        AND (wake_payload->'delivery') ? 'signal_channel_id'
        AND NOT (wake_payload->'delivery') ? 'targets'
      """
    ]
  end

  @doc false
  def down_sqls do
    [
      downgrade_guard_sql("actor_cron_schedules", "delivery", nil),
      downgrade_guard_sql(
        "actor_scheduled_events",
        "wake_payload->'delivery'",
        "kind = 'cron_fire' AND status IN ('scheduled', 'firing')"
      ),
      """
      UPDATE actor_scheduled_events
      SET wake_payload = jsonb_set(
        wake_payload,
        '{delivery}',
        ((wake_payload->'delivery') - 'targets') ||
        jsonb_strip_nulls(
          jsonb_build_object(
            'signal_channel_id', wake_payload#>'{delivery,targets,0,signal_channel_id}',
            'provider_thread_id', wake_payload#>'{delivery,targets,0,provider_thread_id}'
          )
        ),
        true
      )
      WHERE kind = 'cron_fire'
        AND status IN ('scheduled', 'firing')
        AND jsonb_typeof(wake_payload->'delivery'->'targets') = 'array'
      """,
      """
      UPDATE actor_cron_schedules
      SET delivery =
        (delivery - 'targets') ||
        jsonb_strip_nulls(
          jsonb_build_object(
            'signal_channel_id', delivery#>'{targets,0,signal_channel_id}',
            'provider_thread_id', delivery#>'{targets,0,provider_thread_id}'
          )
        )
      WHERE jsonb_typeof(delivery->'targets') = 'array'
      """
    ]
  end

  defp downgrade_guard_sql(table, delivery_expression, extra_where) do
    where =
      [extra_where, "jsonb_typeof(#{delivery_expression}->'targets') = 'array'"]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" AND ")

    """
    DO $cron_delivery_targets_downgrade$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM #{table}
        WHERE #{where}
          AND (
            jsonb_array_length(#{delivery_expression}->'targets') <> 1
            OR #{delivery_expression}#>>'{targets,0,binding_name}' IS DISTINCT FROM binding_name
          )
      ) THEN
        RAISE EXCEPTION 'cron delivery targets cannot be downgraded without losing configured routes';
      END IF;
    END
    $cron_delivery_targets_downgrade$;
    """
  end
end
