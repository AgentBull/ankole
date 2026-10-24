defmodule Ankole.Repo.Migrations.RecordAuthenticationCompletion do
  use Ecto.Migration

  def up do
    alter table(:browser_authentications) do
      add :authenticated_at, :utc_datetime_usec
    end

    execute "UPDATE browser_authentications SET authenticated_at = inserted_at"
    execute "ALTER TABLE browser_authentications ALTER COLUMN authenticated_at SET NOT NULL"
  end

  def down do
    alter table(:browser_authentications) do
      remove :authenticated_at
    end
  end
end
