defmodule Ankole.Repo.Migrations.AddWorkHumanAuthorization do
  use Ecto.Migration

  @tables ~w(actor_events actor_cron_schedules actor_scheduled_events background_agent_jobs workflow_runs automation_jobs)a

  def up do
    for name <- @tables do
      alter table(name) do
        add :authorization_kind, :text, null: false, default: "review_required"
        add :human_uid, references(:human_users, column: :principal_uid, type: :text)
        add :human_access_version, :bigint
      end

      create index(name, [:human_uid])

      create constraint(name, "#{name}_work_authorization_check",
               check:
                 "(authorization_kind = 'human' AND human_uid IS NOT NULL AND human_access_version > 0) OR (authorization_kind IN ('service', 'review_required') AND human_uid IS NULL AND human_access_version IS NULL)"
             )
    end

    flush()

    execute """
    UPDATE actor_events e SET authorization_kind = 'human', human_uid = p.uid, human_access_version = p.access_version
    FROM principals p WHERE p.uid = e.sender_key AND p.type = 'human'
    """

    for name <- ~w(actor_scheduled_events background_agent_jobs workflow_runs automation_jobs) do
      execute """
      UPDATE #{name} w SET authorization_kind = e.authorization_kind, human_uid = e.human_uid, human_access_version = e.human_access_version
      FROM actor_events e WHERE e.id = w.source_actor_event_id AND e.authorization_kind = 'human'
      """
    end

    execute """
    UPDATE actor_cron_schedules w SET authorization_kind = e.authorization_kind, human_uid = e.human_uid, human_access_version = e.human_access_version
    FROM actor_events e WHERE e.id::text = w.created_by->>'actor_event_id' AND e.authorization_kind = 'human'
    """
  end

  def down do
    raise "Retain work authorization and stopped work; restore a compatible runtime"
  end
end
