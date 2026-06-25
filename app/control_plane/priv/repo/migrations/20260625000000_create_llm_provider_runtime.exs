defmodule Ankole.Repo.Migrations.CreateLlmProviderRuntime do
  use Ecto.Migration

  def up do
    create table(:agent_computer_worker_auth_keys, primary_key: false) do
      add :worker_id, :text, primary_key: true
      add :pre_auth_key, :text, null: false
      add :key_revision, :bigint, null: false, default: 1
      add :disabled_at, :utc_datetime_usec
      add :last_bootstrap_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(
             :agent_computer_worker_auth_keys,
             :agent_computer_worker_auth_keys_worker_id_format,
             check: "worker_id ~ '^[a-z][a-z0-9_-]{0,62}$'"
           )

    create constraint(
             :agent_computer_worker_auth_keys,
             :agent_computer_worker_auth_keys_pre_auth_key_present, check: "pre_auth_key <> ''")

    create constraint(
             :agent_computer_worker_auth_keys,
             :agent_computer_worker_auth_keys_revision_positive, check: "key_revision > 0")

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

    drop constraint(:ai_agent_llm_turns, :ai_agent_llm_turns_profile_check)

    create constraint(:ai_agent_llm_turns, :ai_agent_llm_turns_profile_check,
             check: "profile IN ('primary', 'light', 'heavy', 'codex')"
           )
  end

  def down do
    drop constraint(:ai_agent_llm_turns, :ai_agent_llm_turns_profile_check)

    create constraint(:ai_agent_llm_turns, :ai_agent_llm_turns_profile_check,
             check: "profile IN ('primary', 'light', 'heavy')"
           )

    drop index(:llm_providers, [:provider_id], name: :llm_providers_active_index)
    drop index(:llm_providers, [:provider_source], name: :llm_providers_provider_source_index)
    drop table(:llm_providers)
    drop table(:agent_computer_worker_auth_keys)
  end
end
