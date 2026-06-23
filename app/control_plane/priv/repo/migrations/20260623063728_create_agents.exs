defmodule Ankole.Repo.Migrations.CreateAgents do
  use Ecto.Migration

  def change do
    execute(
      "CREATE TYPE agent_type AS ENUM ('ai_colleague')",
      "DROP TYPE agent_type"
    )

    create table(:agents, primary_key: false) do
      add :uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          primary_key: true

      add :type, :agent_type, null: false, default: "ai_colleague"
      add :role, :text, null: false
      add :options, :map, null: false, default: %{}

      add :created_by_principal_uid,
          references(:principals, column: :uid, type: :text, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:agents, [:created_by_principal_uid])

    create constraint(:agents, :agents_role_present, check: "length(btrim(role)) > 0")

    create constraint(:agents, :agents_options_object, check: "jsonb_typeof(options) = 'object'")
  end
end
