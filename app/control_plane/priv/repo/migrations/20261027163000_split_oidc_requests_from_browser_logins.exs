defmodule Ankole.Repo.Migrations.SplitOidcRequestsFromBrowserLogins do
  use Ecto.Migration

  def up do
    create table(:oidc_authorization_requests, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :tenant_id, references(:tenants, type: :uuid, on_delete: :restrict), null: false

      add :browser_id, references(:browser_sessions, type: :uuid, on_delete: :delete_all),
        null: false

      add :client_id, :uuid, null: false
      add :started_revision, :bigint, null: false
      add :status, :text, null: false, default: "pending"
      add :request, :map, null: false, default: %{}

      add :expected_authentication_id,
          references(:browser_authentications, type: :uuid, on_delete: :delete_all)

      add :authentication_id,
          references(:browser_authentications, type: :uuid, on_delete: :delete_all)

      add :authentication_revision, :bigint
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    execute("""
    ALTER TABLE oidc_authorization_requests
      ADD CONSTRAINT oidc_authorization_requests_client_id_fkey
      FOREIGN KEY (tenant_id, client_id) REFERENCES oidc_clients (tenant_id, id)
      ON DELETE CASCADE ON UPDATE NO ACTION
    """)

    create constraint(
             :oidc_authorization_requests,
             :oidc_authorization_requests_started_revision_nonnegative,
             check: "started_revision >= 0"
           )

    create constraint(:oidc_authorization_requests, :oidc_authorization_requests_status,
             check: "status IN ('pending', 'authenticated', 'consumed', 'cancelled')"
           )

    create constraint(:oidc_authorization_requests, :oidc_authorization_requests_authentication,
             check:
               "(authentication_id IS NULL AND authentication_revision IS NULL) OR (authentication_id IS NOT NULL AND authentication_revision > 0)"
           )

    create constraint(:oidc_authorization_requests, :oidc_authorization_requests_request_object,
             check: "jsonb_typeof(request) = 'object'"
           )

    create index(:oidc_authorization_requests, [:tenant_id])
    create index(:oidc_authorization_requests, [:browser_id])
    create index(:oidc_authorization_requests, [:expires_at])

    create table(:browser_oidc_states, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :state, :text, null: false

      add :browser_id, references(:browser_sessions, type: :uuid, on_delete: :delete_all),
        null: false

      add :tenant_id, references(:tenants, type: :uuid, on_delete: :restrict), null: false
      add :provider_id, :text, null: false
      add :purpose, :text, null: false
      add :mode, :text, null: false, default: "replace"
      add :started_revision, :bigint, null: false
      add :redirect_uri, :text, null: false
      add :return_to, :text, null: false, default: "/"
      add :prompt, {:array, :text}, null: false, default: []
      add :invitation_id, :uuid

      add :expected_authentication_id,
          references(:browser_authentications, type: :uuid, on_delete: :delete_all)

      add :reauthentication_principal_uid, :text

      add :oauth_request_id,
          references(:oidc_authorization_requests, type: :uuid, on_delete: :delete_all)

      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:browser_oidc_states, :browser_oidc_states_purpose,
             check: "purpose IN ('console', 'oauth', 'pod')"
           )

    create constraint(:browser_oidc_states, :browser_oidc_states_mode,
             check: "mode IN ('replace', 'add')"
           )

    create constraint(:browser_oidc_states, :browser_oidc_states_started_revision_nonnegative,
             check: "started_revision >= 0"
           )

    create constraint(:browser_oidc_states, :browser_oidc_states_oauth_request,
             check: "(purpose = 'oauth') = (oauth_request_id IS NOT NULL)"
           )

    create unique_index(:browser_oidc_states, [:state])
    create index(:browser_oidc_states, [:browser_id])
    create index(:browser_oidc_states, [:tenant_id])
    create index(:browser_oidc_states, [:expires_at])

    drop constraint(:authn_challenges, :authn_challenges_anchor)
    drop index(:authn_challenges, [:login_transaction_id])

    alter table(:authn_challenges) do
      remove :login_transaction_id
    end

    create constraint(:authn_challenges, :authn_challenges_anchor,
             check: "browser_session_id IS NOT NULL OR purpose = 'setup'"
           )

    drop table(:browser_login_transactions)
  end

  def down do
    create table(:browser_login_transactions, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :browser_id, references(:browser_sessions, type: :uuid, on_delete: :delete_all),
        null: false

      add :tenant_id, references(:tenants, type: :uuid, on_delete: :restrict)
      add :started_revision, :bigint, null: false
      add :purpose, :text, null: false
      add :mode, :text, null: false, default: "replace"
      add :status, :text, null: false, default: "pending"

      add :expected_authentication_id,
          references(:browser_authentications, type: :uuid, on_delete: :nilify_all)

      add :authentication_id,
          references(:browser_authentications, type: :uuid, on_delete: :nilify_all)

      add :authentication_revision, :bigint
      add :csrf_token, :text, null: false
      add :request, :map, null: false, default: %{}
      add :provider_id, :text
      add :upstream_state, :text
      add :redirect_uri, :text
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
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

    create constraint(:browser_login_transactions, :browser_login_transactions_status,
             check: "status IN ('pending', 'authenticated', 'consumed', 'cancelled')"
           )

    create unique_index(:browser_login_transactions, [:upstream_state],
             where: "upstream_state IS NOT NULL"
           )

    create index(:browser_login_transactions, [:browser_id, :started_revision],
             name: :browser_login_transactions_browser_id_started_revision_index
           )

    create index(:browser_login_transactions, [:tenant_id])
    create index(:browser_login_transactions, [:expires_at])

    drop constraint(:authn_challenges, :authn_challenges_anchor)

    alter table(:authn_challenges) do
      add :login_transaction_id,
          references(:browser_login_transactions, type: :uuid, on_delete: :delete_all)
    end

    create index(:authn_challenges, [:login_transaction_id])

    create constraint(:authn_challenges, :authn_challenges_anchor,
             check:
               "login_transaction_id IS NOT NULL OR browser_session_id IS NOT NULL OR purpose = 'setup'"
           )

    drop table(:browser_oidc_states)
    drop table(:oidc_authorization_requests)
  end
end
