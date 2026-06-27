defmodule Ankole.Repo.Migrations.CreateHumanUsers do
  use Ecto.Migration

  def change do
    create table(:human_users, primary_key: false) do
      add :principal_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          primary_key: true

      add :email, :text
      add :mobile, :text
      add :job_title, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:human_users, [:email],
             name: :human_users_email_index,
             where: "email IS NOT NULL"
           )

    create unique_index(:human_users, [:mobile],
             name: :human_users_mobile_index,
             where: "mobile IS NOT NULL"
           )

    comment_table(:human_users, "Human-only profile fields for principals of type human.")

    comment_columns(:human_users, %{
      principal_uid: "Principal uid this human profile extends.",
      email: "Optional human email address used for contact and login binding.",
      mobile: "Optional phone number used for contact and external identity binding.",
      job_title: "Operator-visible role or title for the human."
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
