defmodule Ankole.Repo.Migrations.SeparateBrowserAuthentications do
  use Ecto.Migration

  def up do
    # Existing cookies must sign in again. Keep RP rows for offline grants and
    # pending logout deliveries; their old browser proof cannot issue new codes.
    execute "DELETE FROM browser_login_transactions"
    execute "DELETE FROM oidc_logout_requests"
    execute "UPDATE oidc_sessions SET ended_at = COALESCE(ended_at, CURRENT_TIMESTAMP)"

    drop constraint(:browser_sessions, :browser_sessions_generation_positive)
    rename table(:browser_sessions), :generation, to: :revision

    alter table(:browser_sessions) do
      modify :revision, :bigint, default: 0
      add :logout_revision, :bigint, null: false, default: 0
      add :active_authentication_id, :uuid
      add :active_tenant_id, references(:tenants, type: :uuid, on_delete: :nilify_all)
      remove :revoked_at
      remove :admin_auth
      remove :oauth_auth
    end

    create constraint(:browser_sessions, :browser_sessions_revisions,
             check: "revision >= 0 AND logout_revision >= 0 AND logout_revision <= revision"
           )

    create table(:browser_authentications, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :browser_id, references(:browser_sessions, type: :uuid, on_delete: :delete_all),
        null: false

      add :tenant_id, references(:tenants, type: :uuid, on_delete: :restrict)
      add :provider_id, :text, null: false
      add :subject_id, :text, null: false
      add :external_id, :text
      add :purpose, :text, null: false
      add :revision, :bigint, null: false
      add :auth_time, :bigint
      add :csrf_token, :text, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    execute """
    CREATE UNIQUE INDEX browser_authentications_subject_index
    ON browser_authentications (browser_id, provider_id, subject_id, purpose, tenant_id)
    NULLS NOT DISTINCT
    """

    create constraint(:browser_authentications, :browser_authentications_subject_scope,
             check:
               "(purpose = 'site' AND tenant_id IS NULL) OR (purpose IN ('console', 'oauth', 'pod') AND tenant_id IS NOT NULL)"
           )

    create constraint(:browser_authentications, :browser_authentications_revision_positive,
             check: "revision > 0"
           )

    create table(:browser_pod_authentications, primary_key: false) do
      add :tenant_id, references(:tenants, type: :uuid, on_delete: :restrict), primary_key: true

      add :authentication_id,
          references(:browser_authentications, type: :uuid, on_delete: :delete_all),
          primary_key: true

      add :principal_uid, references(:human_users, column: :principal_uid, type: :text),
        null: false

      add :access_version, :bigint, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:browser_pod_authentications, [:authentication_id])
    create index(:browser_pod_authentications, [:principal_uid])

    drop constraint(:browser_login_transactions, :browser_login_transactions_purpose)
    rename table(:browser_login_transactions), :generation, to: :started_revision

    rename index(:browser_login_transactions, [:browser_id, :generation]),
      to: :browser_login_transactions_browser_id_started_revision_index

    alter table(:browser_login_transactions) do
      modify :tenant_id, :uuid, null: true
      add :mode, :text, null: false, default: "replace"

      add :expected_authentication_id,
          references(:browser_authentications, type: :uuid, on_delete: :nilify_all)

      add :authentication_id,
          references(:browser_authentications, type: :uuid, on_delete: :nilify_all)

      add :authentication_revision, :bigint
      add :csrf_token, :text, null: false
      remove :authentication
    end

    create constraint(:browser_login_transactions, :browser_login_transactions_purpose,
             check: "purpose IN ('console', 'oauth', 'pod', 'site')"
           )

    create constraint(:browser_login_transactions, :browser_login_transactions_mode,
             check: "mode IN ('replace', 'add')"
           )

    create constraint(:browser_login_transactions, :browser_login_transactions_target,
             check:
               "(purpose = 'site' AND tenant_id IS NULL) OR (purpose != 'site' AND tenant_id IS NOT NULL)"
           )

    execute "DROP INDEX oidc_sessions_client_id_browser_id_browser_generation_provider_id_index"

    alter table(:oidc_sessions) do
      add :authentication_id,
          references(:browser_authentications, type: :uuid, on_delete: :nilify_all)

      add :authentication_revision, :bigint
      remove :browser_generation
    end

    create unique_index(:oidc_sessions, [:client_id, :authentication_id, :authentication_revision])

    rename table(:oidc_logout_requests), :browser_generation, to: :browser_revision
  end

  def down do
    raise "Browser authentication migration requires restoring the matching database backup"
  end
end
