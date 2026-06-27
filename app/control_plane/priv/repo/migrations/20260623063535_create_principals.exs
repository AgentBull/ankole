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

    comment_table(:principals, "Canonical actors that can own state or receive authorization.")

    comment_columns(:principals, %{
      uid: "Stable lowercase principal identifier shared by humans and agents.",
      type: "Principal subtype used to route to the matching profile table.",
      status: "Lifecycle state used to disable access without deleting history.",
      display_name: "Operator-visible name for UI and audit surfaces.",
      avatar_url: "Optional avatar image URL for UI rendering."
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
