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

    comment_table(:app_configure, "Typed installation and agent configuration values.")

    comment_columns(:app_configure, %{
      scope: "Configuration owner, either global or a concrete agent scope.",
      key: "Registered configuration key within the scope.",
      value: "Typed configuration envelope with type and value members."
    })
  end

  defp comment_table(table, comment) do
    execute(
      "COMMENT ON TABLE #{identifier(table)} IS #{literal(comment)}",
      "COMMENT ON TABLE #{identifier(table)} IS NULL"
    )
  end

  defp comment_columns(table, comments) do
    Enum.each(comments, fn {column, comment} -> comment_column(table, column, comment) end)
  end

  defp comment_column(table, column, comment) do
    execute(
      "COMMENT ON COLUMN #{identifier(table)}.#{identifier(column)} IS #{literal(comment)}",
      "COMMENT ON COLUMN #{identifier(table)}.#{identifier(column)} IS NULL"
    )
  end

  defp identifier(value), do: "\"" <> String.replace(to_string(value), "\"", "\"\"") <> "\""
  defp literal(value), do: "'" <> String.replace(value, "'", "''") <> "'"
end
