defmodule Ankole.Repo.Migrations.CreateAgentComputerWorkerEnvs do
  # Operator-defined environment variables injected into Agent Computer shells.
  # scope mirrors app_configurations so global defaults and per-agent overrides
  # merge per variable name instead of shadowing a whole configuration key.
  use Ecto.Migration

  def change do
    create table(:agent_computer_worker_envs, primary_key: false) do
      add :scope, :text, null: false
      add :name, :text, null: false
      add :secret, :boolean, null: false
      add :value, :text, null: false
      add :description, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:agent_computer_worker_envs, [:scope, :name],
             name: :agent_computer_worker_envs_scope_name_unique
           )

    # Only installation-wide and concrete agent scopes can own shell variables.
    create constraint(:agent_computer_worker_envs, :agent_computer_worker_envs_scope_check,
             check: "scope = 'global' OR scope ~ '^agent:.+$'"
           )

    # POSIX shell variable names; anything else cannot be exported into a shell.
    create constraint(:agent_computer_worker_envs, :agent_computer_worker_envs_name_check,
             check: "name ~ '^[A-Za-z_][A-Za-z0-9_]*$'"
           )

    comment_table(
      :agent_computer_worker_envs,
      "Operator-defined environment variables for Agent Computer shells."
    )

    comment_columns(:agent_computer_worker_envs, %{
      scope: "Variable owner, either global or a concrete agent scope.",
      name: "POSIX environment variable name within the scope.",
      secret: "Whether value is stored as an AEAD ciphertext.",
      value: "Plaintext value, or the ciphertext when secret.",
      description: "Optional operator note shown in the console."
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
