defmodule Ankole.Repo.Migrations.CreateBrowserSessions do
  use Ecto.Migration

  def change do
    alter table(:principals) do
      add :access_revoked_at, :utc_datetime_usec
    end

    create table(:browser_sessions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :generation, :bigint, null: false, default: 1
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      add :admin_auth, :map
      add :oauth_auth, :map
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:browser_sessions, :browser_sessions_generation_positive,
             check: "generation > 0"
           )

    create index(:browser_sessions, [:expires_at])

    create table(:browser_login_transactions, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :browser_id, references(:browser_sessions, type: :uuid, on_delete: :delete_all),
        null: false

      add :generation, :bigint, null: false
      add :purpose, :text, null: false
      add :status, :text, null: false, default: "pending"
      add :request, :map, null: false, default: %{}
      add :provider_id, :text
      add :upstream_state, :text
      add :redirect_uri, :text
      add :password_ticket, :map
      add :authentication, :map
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:browser_login_transactions, :browser_login_transactions_purpose,
             check: "purpose IN ('console', 'oauth')"
           )

    create constraint(:browser_login_transactions, :browser_login_transactions_status,
             check: "status IN ('pending', 'authenticated', 'consumed', 'cancelled')"
           )

    create unique_index(:browser_login_transactions, [:upstream_state],
             where: "upstream_state IS NOT NULL"
           )

    create index(:browser_login_transactions, [:browser_id, :generation])
    create index(:browser_login_transactions, [:expires_at])
  end
end
