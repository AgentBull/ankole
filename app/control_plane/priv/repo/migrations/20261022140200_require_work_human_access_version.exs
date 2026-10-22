defmodule Ankole.Repo.Migrations.RequireWorkHumanAccessVersion do
  use Ecto.Migration

  @tables ~w(signals cron_schedules scheduled_events background_agent_jobs workflow_runs automation_jobs)a

  def up, do: replace_constraints("human_access_version IS NOT NULL AND ")
  def down, do: replace_constraints("")

  defp replace_constraints(version_presence) do
    for table <- @tables do
      name = "#{table}_work_authorization_check"
      drop(constraint(table, name))

      create(
        constraint(table, name,
          check: """
          (authorization_kind = 'human' AND human_uid IS NOT NULL
            AND #{version_presence}human_access_version > 0)
          OR (authorization_kind IN ('service', 'review_required')
            AND human_uid IS NULL AND human_access_version IS NULL)
          """
        )
      )
    end
  end
end
