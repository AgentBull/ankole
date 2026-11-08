defmodule Ankole.Repo.Migrations.AddBaseSchemaDescriptions do
  use Ecto.Migration

  # Base tables and fields carry a short source description, such as the unit,
  # currency, tax inclusion, or source system, so readers and Agents interpret
  # the values correctly.
  def change do
    alter table(:base_tables) do
      add :description, :text, null: false, default: ""
    end

    alter table(:base_fields) do
      add :description, :text, null: false, default: ""
    end
  end
end
