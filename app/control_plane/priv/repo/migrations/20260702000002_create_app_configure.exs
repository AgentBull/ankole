defmodule Ankole.Repo.Migrations.CreateAppConfigure do
  # AppConfigure：操作员管理的运行时配置存储。
  # scope 是 'global' 或 'agent:<uid>'；value 是带 type 的类型化信封。
  # 与环境变量分开（见 AGENTS.md「bootstrap 配置与 AppConfigure 分离」）。
  use Ecto.Migration

  def change do
    create table(:app_configure, primary_key: false) do
      add :scope, :text, null: false
      add :key, :text, null: false
      add :value, :map, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:app_configure, [:scope, :key], name: :app_configure_scope_key_unique)

    # scope 只允许 global 或 agent:<uid> 前缀。
    create constraint(:app_configure, :app_configure_scope_check,
             check: "scope = 'global' OR scope ~ '^agent:.+$'"
           )

    # value 必须是带 type 和 value 成员的信封对象。
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
