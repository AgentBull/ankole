defmodule Ankole.Repo.Migrations.ReplaceOidcProtocolStorage do
  use Ecto.Migration

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
      add(
        :family_id,
        references(:oidc_refresh_token_families, type: :text, on_delete: :delete_all)
      )

      add(:generation, :integer)
      add(:expires_at, :utc_datetime_usec)
      add(:consumed_at, :utc_datetime_usec)
      add(:successor_ciphertext, :text)
      add(:successor_retry_until, :utc_datetime_usec)
      add(:context, :map)
    end

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
  end

  def down do
    raise "OIDC credential rotation cannot be rolled back"
  end
end
