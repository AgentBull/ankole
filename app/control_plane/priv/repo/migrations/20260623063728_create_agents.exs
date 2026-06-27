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

    comment_table(:agents, "Agent-only profile fields for principals that run work.")

    comment_columns(:agents, %{
      uid: "Principal uid this agent profile extends.",
      type: "Agent subtype; currently all runtime agents are AI colleagues.",
      role: "Human-authored role statement used to frame the agent identity.",
      options: "Agent profile options that are not modeled as first-class columns.",
      created_by_principal_uid: "Human or agent principal that created this agent."
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
