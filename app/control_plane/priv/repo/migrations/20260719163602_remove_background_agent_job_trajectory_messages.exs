defmodule Ankole.Repo.Migrations.RemoveBackgroundAgentJobTrajectoryMessages do
  use Ecto.Migration

  def up do
    drop(constraint(:background_agent_job_turns, :background_agent_job_turns_trajectory_check))

    execute("UPDATE background_agent_job_turns SET trajectory = trajectory - 'messages'")

    create(
      constraint(:background_agent_job_turns, :background_agent_job_turns_trajectory_check,
        check: """
        jsonb_typeof(trajectory) = 'object' AND
        trajectory @> '{"format":"ankole_chatml","version":1}'::jsonb AND
        NOT trajectory ? 'messages'
        """
      )
    )
  end

  def down do
    drop(constraint(:background_agent_job_turns, :background_agent_job_turns_trajectory_check))

    execute(
      "UPDATE background_agent_job_turns " <>
        "SET trajectory = jsonb_set(trajectory, '{messages}', '[]'::jsonb)"
    )

    create(
      constraint(:background_agent_job_turns, :background_agent_job_turns_trajectory_check,
        check: """
        jsonb_typeof(trajectory) = 'object' AND
        trajectory @> '{"format":"ankole_chatml","version":1}'::jsonb AND
        jsonb_typeof(trajectory->'messages') = 'array' AND
        jsonb_array_length(jsonb_path_query_array(trajectory, '$.messages[*].role')) =
          jsonb_array_length(trajectory->'messages') AND
        jsonb_path_query_array(trajectory, '$.messages[*].role') <@
          '["user","developer","assistant","tool"]'::jsonb
        """
      )
    )
  end
end
