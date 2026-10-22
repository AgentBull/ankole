defmodule Ankole.Repo.Migrations.RotateOidcCredentialStorage do
  use Ecto.Migration

  @credential_tables [:oidc_authorization_codes, :oidc_refresh_tokens]

  def up do
    # Authorization challenges were one-way hashes. Only these short-lived
    # grants must be requested again; signed and refresh credentials survive.
    execute("DELETE FROM oidc_authorization_codes")
    drop(constraint(:oidc_authorization_codes, :oidc_authorization_codes_pkce_s256))

    alter table(:oidc_authorization_codes) do
      remove(:state)
      remove(:code_challenge_digest)
      remove(:code_challenge_method)
      add(:code_challenge, :text, null: false)
      add(:consumed_at, :utc_datetime_usec)
      add(:finalized, :boolean, null: false, default: false)
      add(:family_id, :text)
      add(:replay_retain_until, :utc_datetime_usec)
    end

    create(
      constraint(:oidc_authorization_codes, :oidc_authorization_codes_pkce_s256,
        check: "code_challenge ~ '^[A-Za-z0-9_-]{43}$'"
      )
    )

    create constraint(:oidc_authorization_codes, :oidc_authorization_codes_finalization,
             check:
               "NOT finalized OR (consumed_at IS NOT NULL AND replay_retain_until IS NOT NULL)"
           )

    create table(:oidc_refresh_token_families, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:tenant_id, references(:tenants, type: :uuid, on_delete: :restrict), null: false)

      add(:session_id, references(:oidc_sessions, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:family_expires_at, :utc_datetime_usec, null: false)
      add(:revoked_at, :utc_datetime_usec)
    end

    create(index(:oidc_refresh_token_families, [:tenant_id]))
    create(index(:oidc_refresh_token_families, [:session_id]))

    alter table(:oidc_refresh_tokens) do
      add(:family_id, :text)
      add(:generation, :integer)
      add(:expires_at, :utc_datetime_usec)
      add(:consumed_at, :utc_datetime_usec)
      add(:successor_ciphertext, :text)
      add(:successor_retry_until, :utc_datetime_usec)
      add(:context, :map)
    end

    # Each existing refresh token starts its own family at generation 0, so
    # refresh tokens that are in use continue to rotate after the upgrade.
    execute("""
    INSERT INTO oidc_refresh_token_families (id, tenant_id, session_id, family_expires_at)
    SELECT digest, tenant_id, session_id, absolute_expires_at FROM oidc_refresh_tokens
    """)

    execute("""
    UPDATE oidc_refresh_tokens r SET family_id = digest, generation = 0,
      expires_at = absolute_expires_at,
      context = jsonb_build_object('subject', principal_uid, 'client_id', client_id::text,
        'scope', to_jsonb(string_to_array(scope, ' ')), 'resource', '[]'::jsonb,
        'dpop_jkt', NULL, 'acr', NULL, 'auth_time', NULL,
        'family_expires_at', floor(extract(epoch FROM absolute_expires_at))::bigint,
        'claims', jsonb_build_object('session_id', session_id::text))
    """)

    alter table(:oidc_refresh_tokens) do
      modify(:family_id, :text, null: false)
      modify(:generation, :integer, null: false)
      modify(:expires_at, :utc_datetime_usec, null: false)
      modify(:context, :map, null: false)
      remove(:issued_at)
      remove(:absolute_expires_at)
    end

    create(unique_index(:oidc_refresh_tokens, [:family_id, :generation]))
    create(index(:oidc_refresh_tokens, [:expires_at]))

    create(
      constraint(:oidc_refresh_tokens, :oidc_refresh_tokens_generation, check: "generation >= 0")
    )

    create(
      constraint(:oidc_refresh_tokens, :oidc_refresh_tokens_consumption,
        check:
          "(consumed_at IS NULL) = (successor_ciphertext IS NULL AND successor_retry_until IS NULL)"
      )
    )

    create constraint(:oidc_refresh_tokens, :oidc_refresh_tokens_consumption_deadline,
             check:
               "consumed_at IS NULL OR (successor_retry_until IS NOT NULL AND consumed_at < expires_at)"
           )

    create constraint(:oidc_refresh_tokens, :oidc_refresh_tokens_context,
             check: """
             (jsonb_typeof(context) = 'object'
             AND context ?& ARRAY['subject', 'client_id', 'scope', 'claims']
             AND context->>'subject' = principal_uid
             AND context->>'client_id' = client_id::text
             AND context->'claims'->>'session_id' = session_id::text
             AND context->'scope' = to_jsonb(string_to_array(scope, ' '))) IS TRUE
             """
           )

    constrain_session_facts()
    bind_sessions_to_authentication_browsers()
    bind_credentials_to_sessions()
  end

  def down do
    raise "OIDC credential rotation cannot be rolled back"
  end

  defp constrain_session_facts do
    create constraint(:oidc_sessions, :oidc_sessions_access_version_positive,
             check: "access_version > 0"
           )

    create constraint(:oidc_sessions, :oidc_sessions_authentication_revision_positive,
             check: "authentication_revision IS NULL OR authentication_revision > 0"
           )

    create constraint(:oidc_logout_requests, :oidc_logout_requests_browser_revision_nonnegative,
             check: "browser_revision >= 0"
           )

    create constraint(:oidc_logout_deliveries, :oidc_logout_deliveries_attempt_count_nonnegative,
             check: "attempt_count >= 0"
           )
  end

  defp bind_sessions_to_authentication_browsers do
    create unique_index(:browser_authentications, [:browser_id, :id])
    execute("ALTER TABLE oidc_sessions DROP CONSTRAINT oidc_sessions_authentication_id_fkey")

    execute("""
    ALTER TABLE oidc_sessions ADD CONSTRAINT oidc_sessions_authentication_id_fkey
      FOREIGN KEY (browser_id, authentication_id)
      REFERENCES browser_authentications (browser_id, id)
      ON DELETE SET NULL (authentication_id)
    """)
  end

  # A credential and its family belong to the session, client, and principal
  # that issued them. The tenant foreign key migration does not change these keys.
  defp bind_credentials_to_sessions do
    create(
      unique_index(:oidc_sessions, [:tenant_id, :client_id, :principal_uid, :id],
        name: :oidc_sessions_credential_binding_index
      )
    )

    create(
      unique_index(:oidc_refresh_token_families, [:tenant_id, :session_id, :id],
        name: :oidc_refresh_token_families_session_binding_index
      )
    )

    for table <- @credential_tables do
      execute("ALTER TABLE #{table} DROP CONSTRAINT #{table}_session_id_fkey")

      execute("""
      ALTER TABLE #{table} ADD CONSTRAINT #{table}_session_id_fkey
        FOREIGN KEY (tenant_id, client_id, principal_uid, session_id)
        REFERENCES oidc_sessions (tenant_id, client_id, principal_uid, id)
        ON DELETE CASCADE
      """)
    end

    execute("""
    ALTER TABLE oidc_refresh_tokens ADD CONSTRAINT oidc_refresh_tokens_family_id_fkey
      FOREIGN KEY (tenant_id, session_id, family_id)
      REFERENCES oidc_refresh_token_families (tenant_id, session_id, id)
      ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE oidc_authorization_codes ADD CONSTRAINT oidc_authorization_codes_family_id_fkey
      FOREIGN KEY (tenant_id, session_id, family_id)
      REFERENCES oidc_refresh_token_families (tenant_id, session_id, id)
      ON DELETE SET NULL (family_id)
    """)
  end
end
