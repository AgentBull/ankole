defmodule Ankole.Repo.Migrations.CreateAIGatewayProviderRuntime do
  use Ecto.Migration

  def up do
    create table(:ai_gateway_providers, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :provider_id, :text, null: false
      add :provider_kind, :text, null: false
      add :base_url, :text
      add :encrypted_options, :map, null: false, default: %{}
      add :connection_options, :map, null: false, default: %{}
      add :disabled_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:ai_gateway_providers, :ai_gateway_providers_provider_id_format,
             check: "provider_id ~ '^[a-z][a-z0-9_-]{0,62}$'"
           )

    create constraint(:ai_gateway_providers, :ai_gateway_providers_provider_kind_format,
             check: "provider_kind ~ '^[a-z][a-z0-9_-]{0,62}$'"
           )

    create constraint(:ai_gateway_providers, :ai_gateway_providers_base_url_present,
             check: "base_url IS NULL OR base_url <> ''"
           )

    create constraint(:ai_gateway_providers, :ai_gateway_providers_connection_options_object,
             check: "jsonb_typeof(connection_options) = 'object'"
           )

    create constraint(:ai_gateway_providers, :ai_gateway_providers_encrypted_options_object,
             check: "jsonb_typeof(encrypted_options) = 'object'"
           )

    create unique_index(:ai_gateway_providers, [:provider_id],
             name: :ai_gateway_providers_provider_id_index
           )

    create index(:ai_gateway_providers, [:provider_kind],
             name: :ai_gateway_providers_provider_kind_index
           )

    create index(:ai_gateway_providers, [:provider_id],
             name: :ai_gateway_providers_active_index,
             where: "disabled_at IS NULL"
           )

    comment_table(:ai_gateway_providers, "Operator-managed AIGateway provider connections.")

    comment_columns(:ai_gateway_providers, %{
      id: "Opaque UUIDv7 row id used as the provider encrypted option context.",
      provider_id: "Stable operator-facing provider id referenced by model profiles.",
      provider_kind: "Provider kind module id such as OpenRouter, OpenAI, Claude, or Jina.",
      base_url: "Optional provider API base URL override.",
      encrypted_options: "Encrypted provider-kind-specific options stored by the control plane.",
      connection_options:
        "Provider-kind-specific connection options used during runtime resolution.",
      disabled_at: "Time the provider was disabled and excluded from runtime resolution."
    })
  end

  def down do
    drop index(:ai_gateway_providers, [:provider_id], name: :ai_gateway_providers_active_index)

    drop index(:ai_gateway_providers, [:provider_kind],
           name: :ai_gateway_providers_provider_kind_index
         )

    drop unique_index(:ai_gateway_providers, [:provider_id],
           name: :ai_gateway_providers_provider_id_index
         )

    drop table(:ai_gateway_providers)
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
