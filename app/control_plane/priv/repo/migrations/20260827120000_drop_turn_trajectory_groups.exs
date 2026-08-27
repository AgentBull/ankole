defmodule Ankole.Repo.Migrations.DropTurnTrajectoryGroups do
  @moduledoc false

  use Ecto.Migration

  # The TurnItem stream became the only trajectory write and read form on
  # 2026-08-13; the trajectory-group rows were the readable form of Turns
  # recorded before it. Those old Turns now render empty, so the table and
  # its rows go. The raw trajectories they summarized stay unrecoverable by
  # design: the item stream is the retained record.
  def up do
    drop table(:background_agent_job_turn_trajectory_groups)
  end

  def down do
    raise Ecto.MigrationError,
      message: "the dropped trajectory-group rows cannot be restored"
  end
end
