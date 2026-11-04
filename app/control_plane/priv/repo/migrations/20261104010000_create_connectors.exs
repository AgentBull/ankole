defmodule Ankole.Repo.Migrations.CreateConnectors do
  use Ecto.Migration

  def up do
    """
    CREATE TABLE connector_auth_configs (
      id uuid PRIMARY KEY,
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      plugin_id text NOT NULL,
      slug text NOT NULL,
      display_name text NOT NULL,
      auth_scheme text NOT NULL,
      is_default boolean NOT NULL DEFAULT false,
      platform_application text,
      public_metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
      sealed_secret text NOT NULL,
      secret_version bigint NOT NULL DEFAULT 1,
      status text NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'disabled')),
      created_by_uid text NOT NULL,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),

      UNIQUE (tenant_id, id),
      UNIQUE (tenant_id, slug)
    );

    CREATE UNIQUE INDEX connector_auth_configs_default_per_plugin_uidx
      ON connector_auth_configs (tenant_id, plugin_id)
      WHERE is_default = true AND status = 'active';

    CREATE UNIQUE INDEX connector_auth_configs_active_platform_app_uidx
      ON connector_auth_configs (platform_application)
      WHERE status = 'active' AND platform_application IS NOT NULL;


    CREATE TABLE connector_connected_accounts (
      id uuid PRIMARY KEY,
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      auth_config_id uuid NOT NULL,
      plugin_id text NOT NULL,
      subject_kind text NOT NULL
        CHECK (subject_kind IN ('app', 'human')),
      account_key text NOT NULL,
      owner_principal_uid text,
      owner_access_version bigint,
      external_subject_id text,
      granted_scopes text[] NOT NULL DEFAULT '{}'::text[],
      public_metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
      sealed_credentials text,
      credentials_version bigint NOT NULL DEFAULT 1,
      status text NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'expired', 'revoked', 'disabled')),
      expires_at timestamptz,
      refresh_expires_at timestamptz,
      refreshing_until timestamptz,
      refresh_lease_id text,
      last_refreshed_at timestamptz,
      last_refresh_failure_at timestamptz,
      first_refresh_failure_at timestamptz,
      last_error jsonb,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),

      UNIQUE (tenant_id, id),
      UNIQUE (tenant_id, auth_config_id, subject_kind, account_key),
      FOREIGN KEY (tenant_id, auth_config_id)
        REFERENCES connector_auth_configs(tenant_id, id) ON DELETE CASCADE,
      CHECK (
        (subject_kind = 'app' AND owner_principal_uid IS NULL) OR
        (subject_kind = 'human' AND owner_principal_uid IS NOT NULL AND sealed_credentials IS NOT NULL)
      )
    );

    CREATE INDEX connector_connected_accounts_human_owner_idx
      ON connector_connected_accounts (tenant_id, owner_principal_uid)
      WHERE subject_kind = 'human';

    CREATE INDEX connector_connected_accounts_proactive_refresh_idx
      ON connector_connected_accounts (refresh_expires_at)
      WHERE status = 'active' AND refresh_expires_at IS NOT NULL;


    CREATE TABLE connector_oauth_sessions (
      id uuid PRIMARY KEY,
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      auth_config_id uuid NOT NULL,
      subject_kind text NOT NULL CHECK (subject_kind IN ('app', 'human')),
      actor_uid text NOT NULL,
      oauth_state_digest bytea NOT NULL UNIQUE,
      completion_code_digest bytea UNIQUE,
      sealed_pkce_verifier text,
      sealed_pending_tokens text,
      requested_scopes text[] NOT NULL DEFAULT '{}'::text[],
      return_to text,
      status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'callback_received', 'completed', 'expired', 'failed')),
      expires_at timestamptz NOT NULL,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),

      FOREIGN KEY (tenant_id, auth_config_id)
        REFERENCES connector_auth_configs(tenant_id, id) ON DELETE CASCADE
    );


    CREATE TABLE connector_triggers (
      id uuid PRIMARY KEY,
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      auth_config_id uuid NOT NULL,
      connected_account_id uuid,
      plugin_id text NOT NULL,
      trigger_type text NOT NULL,
      scope_key text NOT NULL,
      config jsonb NOT NULL DEFAULT '{}'::jsonb,
      external_subscription_id text,
      sealed_secret text,
      status text NOT NULL DEFAULT 'provisioning'
        CHECK (status IN ('provisioning', 'active', 'degraded', 'paused', 'deleting')),
      lease_expires_at timestamptz,
      last_error jsonb,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),

      UNIQUE (tenant_id, id),
      UNIQUE (tenant_id, auth_config_id, trigger_type, scope_key),
      FOREIGN KEY (tenant_id, auth_config_id)
        REFERENCES connector_auth_configs(tenant_id, id) ON DELETE RESTRICT,
      FOREIGN KEY (tenant_id, connected_account_id)
        REFERENCES connector_connected_accounts(tenant_id, id) ON DELETE RESTRICT
    );


    ALTER TABLE signal_bindings
      ADD COLUMN auth_config_id uuid,
      ADD CONSTRAINT signal_bindings_auth_config_fkey
        FOREIGN KEY (tenant_id, auth_config_id)
        REFERENCES connector_auth_configs(tenant_id, id) ON DELETE RESTRICT;

    """
    |> String.split(";", trim: true)
    |> Enum.each(&execute/1)
  end

  def down do
    execute("ALTER TABLE signal_bindings DROP COLUMN auth_config_id")
    drop(table(:connector_triggers))
    drop(table(:connector_oauth_sessions))
    drop(table(:connector_connected_accounts))
    drop(table(:connector_auth_configs))
  end
end
