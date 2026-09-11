defmodule Ankole.Repo.Migrations.ExtendOidcSessionProtocols do
  use Ecto.Migration

  def change do
    alter table(:oidc_clients) do
      add :allowed_identity_provider_ids, {:array, :text}, null: false, default: []
      add :backchannel_logout_uri, :text
      add :backchannel_logout_session_required, :boolean, null: false, default: true
      add :post_logout_redirect_uris, {:array, :text}, null: false, default: []
      add :allow_insecure_local_logout, :boolean, null: false, default: false
    end

    create table(:oidc_sessions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :client_id, references(:oidc_clients, type: :uuid, on_delete: :delete_all), null: false

      add :principal_uid, references(:human_users, column: :principal_uid, type: :text),
        null: false

      add :browser_id, references(:browser_sessions, type: :uuid), null: false
      add :browser_generation, :bigint, null: false
      add :access_version, :bigint, null: false
      add :provider_id, :text, null: false
      add :auth_time, :bigint
      add :expires_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:oidc_sessions, [
             :client_id,
             :browser_id,
             :browser_generation,
             :provider_id
           ])

    create index(:oidc_sessions, [:principal_uid, :access_version])

    alter table(:oidc_authorization_codes) do
      add :session_id, references(:oidc_sessions, type: :uuid, on_delete: :delete_all)
    end

    alter table(:oidc_refresh_tokens) do
      add :session_id, references(:oidc_sessions, type: :uuid, on_delete: :delete_all)
    end

    create index(:oidc_authorization_codes, [:session_id])
    create index(:oidc_refresh_tokens, [:session_id])

    create table(:oidc_logout_deliveries, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :session_id, references(:oidc_sessions, type: :uuid, on_delete: :delete_all),
        null: false

      add :endpoint, :text, null: false
      add :status, :text, null: false, default: "pending"
      add :attempt_count, :integer, null: false, default: 0
      add :last_attempt_at, :utc_datetime_usec
      add :next_attempt_at, :utc_datetime_usec
      add :delivered_at, :utc_datetime_usec
      add :deadline, :utc_datetime_usec, null: false
      add :last_error, :text
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:oidc_logout_deliveries, [:session_id])

    create constraint(:oidc_logout_deliveries, :oidc_logout_deliveries_status,
             check: "status IN ('pending', 'delivering', 'delivered', 'failed')"
           )

    create table(:oidc_logout_requests, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :browser_id, references(:browser_sessions, type: :uuid, on_delete: :delete_all),
        null: false

      add :browser_generation, :bigint, null: false
      add :client_id, references(:oidc_clients, type: :uuid, on_delete: :delete_all)
      add :redirect_uri, :text
      add :state, :text
      add :expires_at, :utc_datetime_usec, null: false
      add :confirmed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:oidc_logout_requests, [:expires_at])
  end
end
