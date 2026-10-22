defmodule Ankole.Repo.Migrations.ConstrainPodDatabaseFacts do
  use Ecto.Migration

  def change do
    create constraint(:db_tables, :db_tables_counters,
             check: "data_version >= 0 AND record_count >= 0 AND next_auto_number > 0"
           )

    for table <- [:db_fields, :db_views] do
      create constraint(table, :"#{table}_version", check: "version > 0")

      create constraint(table, :"#{table}_config_object",
               check: "jsonb_typeof(config) = 'object'"
             )
    end

    create constraint(:db_records, :db_records_value_objects,
             check: "jsonb_typeof(data) = 'object' AND jsonb_typeof(versions) = 'object'"
           )
  end
end
