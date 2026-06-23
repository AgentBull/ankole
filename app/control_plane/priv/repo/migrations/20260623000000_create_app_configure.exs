defmodule Ankole.Repo.Migrations.CreateAppConfigure do
  use Ecto.Migration

  def change do
    create table(:app_configure, primary_key: false) do
      add :scope, :text, null: false
      add :key, :text, null: false
      add :value, :map, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:app_configure, [:scope, :key], name: :app_configure_scope_key_unique)

    create constraint(:app_configure, :app_configure_scope_check,
             check: "scope = 'global' OR scope ~ '^agent:.+$'"
           )

    create constraint(:app_configure, :app_configure_value_envelope_check,
             check: "jsonb_typeof(value) = 'object' AND value ? 'type' AND value ? 'value'"
           )
  end
end
