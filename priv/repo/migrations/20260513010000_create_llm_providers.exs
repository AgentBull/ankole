defmodule BullX.Repo.Migrations.CreateLLMProviders do
  use Ecto.Migration

  def change do
    create table(:llm_providers, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :provider_id, :text, null: false
      add :req_llm_provider, :text, null: false
      add :base_url, :text
      add :encrypted_api_key, :text
      add :provider_options, :jsonb, null: false, default: fragment("'{}'::jsonb")

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:llm_providers, [:provider_id])

    create constraint(:llm_providers, :llm_providers_provider_id_format,
             check: "provider_id ~ '^[a-z][a-z0-9_-]{0,62}$'"
           )

    create constraint(:llm_providers, :llm_providers_req_llm_provider_format,
             check: "req_llm_provider ~ '^[a-z][a-z0-9_]{0,62}$'"
           )

    create constraint(:llm_providers, :llm_providers_provider_options_object,
             check: "jsonb_typeof(provider_options) = 'object'"
           )

    create constraint(:llm_providers, :llm_providers_encrypted_api_key_not_empty,
             check: "encrypted_api_key IS NULL OR encrypted_api_key <> ''"
           )
  end
end
