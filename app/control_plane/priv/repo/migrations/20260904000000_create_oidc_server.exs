defmodule Ankole.Repo.Migrations.CreateOIDCServer do
  use Ecto.Migration

  def change do
    create table(:oidc_signing_keys, primary_key: false) do
      add :id, :text, primary_key: true
      add :kid, :text, null: false
      add :public_jwk, :map, null: false
      add :private_key_ciphertext, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:oidc_signing_keys, :oidc_signing_keys_primary_only,
             check: "id = 'primary'"
           )

    create unique_index(:oidc_signing_keys, [:kid])

    create table(:oidc_clients, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :text, null: false
      add :enabled, :boolean, null: false, default: true
      add :client_type, :text, null: false
      add :secret_ciphertext, :text
      add :redirect_uris, {:array, :text}, null: false, default: []
      add :scopes, {:array, :text}, null: false, default: []
      add :model_aliases, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:oidc_clients, :oidc_clients_name_present, check: "btrim(name) <> ''")

    create constraint(:oidc_clients, :oidc_clients_type,
             check: "client_type IN ('public', 'confidential')"
           )

    create constraint(:oidc_clients, :oidc_clients_secret_shape,
             check:
               "(client_type = 'public' AND secret_ciphertext IS NULL) OR " <>
                 "(client_type = 'confidential' AND secret_ciphertext IS NOT NULL)"
           )

    create constraint(:oidc_clients, :oidc_clients_openid_scope,
             check: "scopes @> ARRAY['openid']::text[]"
           )

    create constraint(:oidc_clients, :oidc_clients_gateway_models,
             check: "NOT ('ai_gateway.write' = ANY(scopes)) OR model_aliases <> '{}'::jsonb"
           )

    create table(:oidc_client_groups, primary_key: false) do
      add :client_id,
          references(:oidc_clients, type: :uuid, on_delete: :delete_all),
          primary_key: true

      add :group_id,
          references(:principal_groups, type: :uuid, on_delete: :delete_all),
          primary_key: true

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:oidc_client_groups, [:group_id])

    create table(:oidc_authorization_codes, primary_key: false) do
      add :digest, :text, primary_key: true
      add :client_id, references(:oidc_clients, type: :uuid, on_delete: :delete_all), null: false

      add :principal_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          null: false

      add :redirect_uri, :text, null: false
      add :scope, :text, null: false
      add :state, :text
      add :nonce, :text
      add :code_challenge_digest, :text, null: false
      add :code_challenge_method, :text, null: false
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:oidc_authorization_codes, :oidc_authorization_codes_pkce_s256,
             check: "code_challenge_method = 'S256'"
           )

    create index(:oidc_authorization_codes, [:expires_at])

    create table(:oidc_refresh_tokens, primary_key: false) do
      add :digest, :text, primary_key: true
      add :client_id, references(:oidc_clients, type: :uuid, on_delete: :delete_all), null: false

      add :principal_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          null: false

      add :scope, :text, null: false
      add :issued_at, :utc_datetime_usec, null: false
      add :absolute_expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:oidc_refresh_tokens, [:client_id])
    create index(:oidc_refresh_tokens, [:principal_uid])
    create index(:oidc_refresh_tokens, [:absolute_expires_at])
  end
end
