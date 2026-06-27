defmodule Ankole.Repo.Migrations.CreateLlmProviderRuntime do
  use Ecto.Migration

  def up do
    create table(:llm_providers, primary_key: false) do
      add :provider_id, :text, primary_key: true
      add :provider_source, :text, null: false
      add :base_url, :text
      add :encrypted_credential, :text
      add :credential_mode, :text, null: false, default: "api_key"
      add :connection_options, :map, null: false, default: %{}
      add :disabled_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:llm_providers, :llm_providers_provider_id_format,
             check: "provider_id ~ '^[a-z][a-z0-9_-]{0,62}$'"
           )

    create constraint(:llm_providers, :llm_providers_provider_source_check,
             check: "provider_source IN ('openrouter', 'openai', 'claude', 'gemini')"
           )

    create constraint(:llm_providers, :llm_providers_credential_mode_check,
             check: "credential_mode IN ('api_key', 'auth_token')"
           )

    create constraint(:llm_providers, :llm_providers_base_url_present,
             check: "base_url IS NULL OR base_url <> ''"
           )

    create constraint(:llm_providers, :llm_providers_encrypted_credential_present,
             check: "encrypted_credential IS NULL OR encrypted_credential <> ''"
           )

    create constraint(:llm_providers, :llm_providers_connection_options_object,
             check: "jsonb_typeof(connection_options) = 'object'"
           )

    create index(:llm_providers, [:provider_source], name: :llm_providers_provider_source_index)

    create index(:llm_providers, [:provider_id],
             name: :llm_providers_active_index,
             where: "disabled_at IS NULL"
           )

    comment_table(:llm_providers, "Operator-managed LLM provider connections.")

    comment_columns(:llm_providers, %{
      provider_id: "Stable provider id referenced by agent model profiles.",
      provider_source: "Provider implementation family such as OpenRouter or OpenAI.",
      base_url: "Optional provider API base URL override.",
      encrypted_credential: "Encrypted provider credential stored by the control plane.",
      credential_mode: "Credential presentation mode expected by the provider.",
      connection_options: "Provider-specific options applied when resolving runtime credentials.",
      disabled_at: "Time the provider was disabled and excluded from runtime resolution."
    })
  end

  def down do
    drop index(:llm_providers, [:provider_id], name: :llm_providers_active_index)
    drop index(:llm_providers, [:provider_source], name: :llm_providers_provider_source_index)
    drop table(:llm_providers)
  end

  defp comment_table(table, comment) do
    execute("COMMENT ON TABLE #{identifier(table)} IS #{literal(comment)}")
  end

  defp comment_columns(table, comments) do
    Enum.each(comments, fn {column, comment} -> comment_column(table, column, comment) end)
  end

  defp comment_column(table, column, comment) do
    execute("COMMENT ON COLUMN #{identifier(table)}.#{identifier(column)} IS #{literal(comment)}")
  end

  defp identifier(value), do: "\"" <> String.replace(to_string(value), "\"", "\"\"") <> "\""
  defp literal(value), do: "'" <> String.replace(value, "'", "''") <> "'"
end
