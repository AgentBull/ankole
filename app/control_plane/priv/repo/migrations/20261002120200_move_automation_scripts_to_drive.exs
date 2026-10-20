defmodule Ankole.Repo.Migrations.MoveAutomationScriptsToDrive do
  use Ecto.Migration

  # An Automation Job script now lives in the Agent's drive at `drive_prefix`.
  # Existing jobs get the folder `automation/<id>`; `legacy_directory_path`
  # keeps their old Agent Home directory so that the one-time import
  # (`Ankole.Upgrade202610.import_agent_home/1`) can copy each script into that
  # folder and clear the column. A later release drops the column once no
  # instance has a job that still needs the import.
  def up do
    rename table(:automation_jobs), :directory_path, to: :legacy_directory_path

    execute "ALTER TABLE automation_jobs ALTER COLUMN legacy_directory_path DROP NOT NULL"

    execute "ALTER TABLE automation_jobs DROP CONSTRAINT automation_jobs_directory_path_present"

    alter table(:automation_jobs) do
      add :drive_prefix, :text
    end

    execute "UPDATE automation_jobs SET drive_prefix = 'automation/' || id::text"
    execute "ALTER TABLE automation_jobs ALTER COLUMN drive_prefix SET NOT NULL"

    create constraint(:automation_jobs, :automation_jobs_drive_prefix_present,
             check: "length(btrim(drive_prefix)) > 0"
           )
  end

  def down do
    raise Ecto.MigrationError, message: "Automation Job scripts moved into Agent drives"
  end
end
