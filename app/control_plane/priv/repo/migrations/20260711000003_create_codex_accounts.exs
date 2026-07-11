defmodule Ankole.Repo.Migrations.CreateCodexAccounts do
  use Ecto.Migration

  def up do
    execute("DELETE FROM app_configurations WHERE key = 'agent_computer.codex.config_override'")

    create table(:codex_accounts, primary_key: false) do
      add(:account_id, :text, primary_key: true)
      add(:name, :text, null: false)
      add(:encrypted_auth_json, :text, null: false)
      add(:auth_hash, :text, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    execute(
      "CREATE UNIQUE INDEX codex_accounts_name_lower_index ON codex_accounts (lower(name))",
      "DROP INDEX codex_accounts_name_lower_index"
    )

    create constraint(:codex_accounts, :codex_accounts_name_present, check: "btrim(name) <> ''")

    create constraint(:codex_accounts, :codex_accounts_auth_present,
             check: "encrypted_auth_json <> ''"
           )

    create constraint(:codex_accounts, :codex_accounts_hash_present, check: "auth_hash <> ''")

    alter table(:subagent_delegations) do
      add(:codex_account_id, :text, null: false, default: "aigateway")
    end

    create index(:subagent_delegations, [:codex_account_id, :status],
             name: :subagent_delegations_codex_account_status_index
           )
  end

  def down do
    drop_if_exists(
      index(:subagent_delegations, [:codex_account_id, :status],
        name: :subagent_delegations_codex_account_status_index
      )
    )

    alter table(:subagent_delegations) do
      remove(:codex_account_id)
    end

    drop(table(:codex_accounts))
  end
end
