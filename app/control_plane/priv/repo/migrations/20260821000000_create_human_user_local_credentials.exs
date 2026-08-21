defmodule Ankole.Repo.Migrations.CreateHumanUserLocalCredentials do
  use Ecto.Migration

  def change do
    # Only a human user can hold a local password, so the credential row keys
    # on human_users and not on principals.
    create table(:human_user_local_credentials, primary_key: false) do
      add :principal_uid,
          references(:human_users, column: :principal_uid, type: :text, on_delete: :delete_all),
          primary_key: true

      add :password_hash, :text, null: false
      add :must_change_password, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    comment_table(
      :human_user_local_credentials,
      "Local email-and-password sign-in credentials for human users."
    )

    comment_columns(:human_user_local_credentials, %{
      principal_uid: "Human user this credential belongs to.",
      password_hash: "Argon2id password hash in PHC string format.",
      must_change_password: "When true, the user must set a new password at the next sign-in."
    })
  end

  defp comment_table(table, comment) do
    execute(
      "COMMENT ON TABLE #{identifier(table)} IS #{literal(comment)}",
      "COMMENT ON TABLE #{identifier(table)} IS NULL"
    )
  end

  defp comment_columns(table, comments) do
    Enum.each(comments, fn {column, comment} ->
      execute(
        "COMMENT ON COLUMN #{identifier(table)}.#{identifier(column)} IS #{literal(comment)}",
        "COMMENT ON COLUMN #{identifier(table)}.#{identifier(column)} IS NULL"
      )
    end)
  end

  defp identifier(value), do: "\"" <> String.replace(to_string(value), "\"", "\"\"") <> "\""
  defp literal(value), do: "'" <> String.replace(value, "'", "''") <> "'"
end
