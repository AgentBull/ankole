defmodule Ankole.Repo.Migrations.CreatePodAppletEnvs do
  use Ecto.Migration

  def up do
    create table(:pod_applet_envs, primary_key: false) do
      add :tenant_id, references(:tenants, type: :uuid, on_delete: :restrict),
        primary_key: true,
        null: false

      add :page_id, :uuid, primary_key: true, null: false
      add :name, :text, primary_key: true, null: false
      add :secret, :boolean, null: false
      add :value, :text, null: false
      add :description, :text
      timestamps(type: :utc_datetime_usec)
    end

    execute(
      "ALTER TABLE pod_applet_envs ADD CONSTRAINT pod_applet_envs_page_fkey FOREIGN KEY (tenant_id, page_id) REFERENCES pages(tenant_id, id) ON DELETE CASCADE"
    )

    create constraint(:pod_applet_envs, :pod_applet_envs_name_check,
             check: "name ~ '^[A-Za-z_][A-Za-z0-9_]*$'"
           )
  end

  def down do
    drop table(:pod_applet_envs)
  end
end
