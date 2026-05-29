defmodule BullX.Repo.Migrations.CreateAppConfigs do
  use Ecto.Migration

  def change do
    execute(
      "CREATE TYPE app_config_type AS ENUM ('plain', 'secret')",
      "DROP TYPE app_config_type"
    )

    create table(:app_configs, primary_key: false) do
      add :key, :text, primary_key: true
      add :type, :app_config_type, null: false, default: "plain"
      add :value, :text, null: false
      timestamps(type: :utc_datetime)
    end
  end
end
