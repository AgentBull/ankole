defmodule Ankole.Repo.Migrations.IndexPodOwners do
  use Ecto.Migration

  def change do
    create index(:db_tables, [:tenant_id, :page_id, :position])
    create index(:db_views, [:tenant_id, :table_id, :position])
    create index(:page_user_states, [:tenant_id, :page_id])

    create unique_index(:automation_jobs, [:tenant_id, :id])

    execute(
      "ALTER TABLE db_sync_bindings ADD CONSTRAINT db_sync_bindings_automation_job_fkey " <>
        "FOREIGN KEY (tenant_id, automation_job_id) REFERENCES automation_jobs (tenant_id, id) " <>
        "ON DELETE RESTRICT",
      "ALTER TABLE db_sync_bindings DROP CONSTRAINT db_sync_bindings_automation_job_fkey"
    )
  end
end
