defmodule Ankole.Repo.Migrations.CreatePrincipals do
  use Ecto.Migration

  def change do
    execute(
      "CREATE TYPE principal_type AS ENUM ('human', 'agent')",
      "DROP TYPE principal_type"
    )

    execute(
      "CREATE TYPE principal_status AS ENUM ('active', 'disabled')",
      "DROP TYPE principal_status"
    )

    create table(:principals, primary_key: false) do
      add :uid, :text, primary_key: true
      add :type, :principal_type, null: false
      add :status, :principal_status, null: false, default: "active"
      add :display_name, :text
      add :avatar_url, :text

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:principals, :principals_uid_present, check: "length(btrim(uid)) > 0")

    create constraint(:principals, :principals_uid_lowercase, check: "uid = lower(uid)")
  end
end
