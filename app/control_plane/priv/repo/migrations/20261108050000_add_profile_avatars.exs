defmodule Ankole.Repo.Migrations.AddProfileAvatars do
  use Ecto.Migration

  def up do
    alter table(:tenants) do
      add :avatar_url, :text
    end

    create table(:profile_avatars, primary_key: false) do
      add :tenant_id, references(:tenants, type: :uuid, on_delete: :restrict),
        primary_key: true,
        null: false

      add :key, :text, primary_key: true, null: false
      add :object_id, :uuid, null: false
      add :content_type, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:profile_avatars, [:tenant_id, :object_id])

    execute(
      "ALTER TABLE profile_avatars ADD CONSTRAINT profile_avatars_object_fkey FOREIGN KEY (tenant_id, object_id) REFERENCES file_objects(tenant_id, id) ON DELETE RESTRICT"
    )

    create constraint(:profile_avatars, :profile_avatars_content_type,
             check: "content_type IN ('image/png', 'image/jpeg', 'image/gif', 'image/webp')"
           )
  end

  def down do
    drop table(:profile_avatars)

    alter table(:tenants) do
      remove :avatar_url
    end
  end
end
