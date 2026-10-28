defmodule Ankole.Repo.Migrations.AuthorizeConsoleCronAsService do
  use Ecto.Migration

  @console_cron """
  cron.authorization_kind = 'human'
    AND cron.status IN ('active', 'paused')
    AND cron.created_by->>'kind' = 'operator_api'
    AND EXISTS (
      SELECT 1 FROM principals AS creator
      WHERE creator.uid = cron.human_uid AND creator.type = 'human'
        AND cron.created_by->>'principal_uid' =
          'ankole:' || creator.tenant_id::text || ':principal/' || creator.uid
    )
  """

  def up do
    # Match pending fires before clearing the rule's previous Human snapshot.
    execute """
    UPDATE scheduled_events AS event
    SET authorization_kind = 'service', human_uid = NULL, human_access_version = NULL
    FROM cron_schedules AS cron
    WHERE #{@console_cron}
      AND event.tenant_id = cron.tenant_id
      AND event.agent_uid = cron.agent_uid
      AND event.cron_schedule_id = cron.id
      AND event.kind = 'cron_fire' AND event.status = 'scheduled'
      AND event.authorization_kind = 'human'
      AND event.human_uid = cron.human_uid
      AND event.human_access_version = cron.human_access_version
    """

    execute """
    UPDATE cron_schedules AS cron
    SET authorization_kind = 'service', human_uid = NULL, human_access_version = NULL
    WHERE #{@console_cron}
    """
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "Console cron service authority cannot restore the previous Human authorization snapshot"
  end
end
