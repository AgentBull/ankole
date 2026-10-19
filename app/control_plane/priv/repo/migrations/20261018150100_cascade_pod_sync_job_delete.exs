defmodule Ankole.Repo.Migrations.CascadePodSyncJobDelete do
  use Ecto.Migration

  def up, do: replace_job_constraint("CASCADE")
  def down, do: replace_job_constraint("RESTRICT")

  defp replace_job_constraint(on_delete) do
    execute("ALTER TABLE db_sync_bindings DROP CONSTRAINT db_sync_bindings_automation_job_fkey")

    execute(
      "ALTER TABLE db_sync_bindings ADD CONSTRAINT db_sync_bindings_automation_job_fkey " <>
        "FOREIGN KEY (tenant_id, automation_job_id) REFERENCES automation_jobs (tenant_id, id) " <>
        "ON DELETE " <> on_delete
    )
  end
end
