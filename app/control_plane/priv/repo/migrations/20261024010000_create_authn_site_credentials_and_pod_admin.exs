defmodule Ankole.Repo.Migrations.CreateAuthnSiteCredentialsAndPodAdmin do
  use Ecto.Migration

  def up do
    Ankole.CredentialUpgrade.preflight!(repo())

    alter table(:human_access_restrictions) do
      add :disposition, :text
    end

    execute """
    UPDATE human_access_restrictions SET disposition = CASE
      WHEN reason IN ('departure', 'enterprise_exit', 'directory_removal', 'departed', 'offboarded', 'self_exit')
        OR (source LIKE 'provider:%' AND reason <> 'suspended') THEN 'offboarded'
      ELSE 'suspended' END
    """

    execute "ALTER TABLE human_access_restrictions ALTER COLUMN disposition SET NOT NULL"

    create constraint(:human_access_restrictions, :human_access_restrictions_disposition,
             check: "disposition IN ('suspended', 'offboarded')"
           )

    drop index(:human_access_restrictions, [:tenant_id, :principal_uid, :source, :reason],
           name: :human_access_restrictions_active_index
         )

    create unique_index(
             :human_access_restrictions,
             [:tenant_id, :principal_uid, :source, :disposition, :reason],
             where: "cleared_at IS NULL",
             name: :human_access_restrictions_active_index
           )

    alter table(:human_access_events) do
      add :released_identifiers, {:array, :text}, null: false, default: []
    end

    create index(:human_access_events, [:released_identifiers],
             using: :gin,
             where: "cardinality(released_identifiers) > 0"
           )

    alter table(:browser_authentications) do
      add :challenge_started_at, :utc_datetime_usec
      add :amr, {:array, :text}, null: false, default: []
      add :verified_email, :text
      add :verified_phone, :text
    end

    execute "UPDATE browser_authentications SET challenge_started_at = inserted_at"
    execute "ALTER TABLE browser_authentications ALTER COLUMN challenge_started_at SET NOT NULL"

    create table(:principal_site_credentials, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :tenant_id, references(:tenants, type: :uuid, on_delete: :restrict), null: false
      add :principal_uid, :text, null: false
      add :kind, :text, null: false
      add :provider, :text, null: false
      add :identifier, :text, null: false
      add :verified_email, :text
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    execute """
    ALTER TABLE principal_site_credentials ADD CONSTRAINT principal_site_credentials_human_fkey
      FOREIGN KEY (tenant_id, principal_uid) REFERENCES human_users (tenant_id, principal_uid)
      ON DELETE CASCADE
    """

    create constraint(:principal_site_credentials, :principal_site_credentials_kind,
             check: "kind IN ('otp', 'oidc', 'webauthn')"
           )

    create constraint(:principal_site_credentials, :principal_site_credentials_email,
             check:
               "provider <> 'email_otp' OR (kind = 'otp' AND verified_email IS NOT NULL AND verified_email = identifier AND identifier <> '' AND identifier = lower(btrim(identifier)))"
           )

    create constraint(:principal_site_credentials, :principal_site_credentials_metadata,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    create unique_index(:principal_site_credentials, [:tenant_id, :provider, :identifier],
             name: :principal_site_credentials_provider_identifier_uidx
           )

    create unique_index(:principal_site_credentials, [:tenant_id, :principal_uid, :provider],
             where: "kind IN ('otp', 'oidc')",
             name: :principal_site_credentials_principal_provider_uidx
           )

    create index(:principal_site_credentials, [:provider, :identifier],
             name: :principal_site_credentials_cross_pod_lookup_idx
           )

    create table(:authn_challenges, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :strategy, :text, null: false
      add :purpose, :text, null: false
      add :factor_stage, :text, null: false, default: "primary"

      add :login_transaction_id,
          references(:browser_login_transactions, type: :uuid, on_delete: :delete_all)

      add :browser_session_id, references(:browser_sessions, type: :uuid, on_delete: :delete_all)
      add :tenant_id, references(:tenants, type: :uuid, on_delete: :restrict)
      add :principal_uid, :text
      add :target, :text
      add :secret_digest, :binary
      add :ceremony_context, :map, null: false, default: %{}
      add :attempt_count, :integer, null: false, default: 0
      add :max_attempts, :integer, null: false, default: 5
      add :challenge_started_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec
      add :verified_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:authn_challenges, :authn_challenges_anchor,
             check:
               "login_transaction_id IS NOT NULL OR browser_session_id IS NOT NULL OR purpose = 'setup'"
           )

    create constraint(:authn_challenges, :authn_challenges_target,
             check: "target IS NOT NULL OR principal_uid IS NOT NULL OR strategy = 'passkey'"
           )

    create constraint(:authn_challenges, :authn_challenges_attempts,
             check: "attempt_count >= 0 AND max_attempts >= 1 AND attempt_count <= max_attempts"
           )

    create constraint(:authn_challenges, :authn_challenges_factor_stage,
             check: "factor_stage IN ('primary', 'secondary', 'step_up')"
           )

    create constraint(:authn_challenges, :authn_challenges_consumed,
             check:
               "(verified_at IS NULL AND attempt_count < max_attempts) OR (secret_digest IS NULL AND expires_at IS NULL)"
           )

    create index(:authn_challenges, [:login_transaction_id])
    create index(:authn_challenges, [:inserted_at])

    create table(:pod_invitations, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :tenant_id, references(:tenants, type: :uuid, on_delete: :restrict), null: false
      add :kind, :text, null: false
      add :invited_email, :text
      add :membership, :text, null: false, default: "member"
      add :token_digest, :binary, null: false
      add :code_digest, :binary, null: false
      add :max_uses, :integer
      add :used_count, :integer, null: false, default: 0
      add :created_by_principal_uid, :text, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    execute """
    ALTER TABLE pod_invitations ADD CONSTRAINT pod_invitations_creator_fkey
      FOREIGN KEY (tenant_id, created_by_principal_uid) REFERENCES principals (tenant_id, uid)
    """

    create constraint(:pod_invitations, :pod_invitations_target,
             check:
               "(kind = 'email' AND invited_email IS NOT NULL) OR (kind = 'link' AND invited_email IS NULL)"
           )

    create constraint(:pod_invitations, :pod_invitations_membership,
             check: "membership IN ('member', 'guest')"
           )

    create constraint(:pod_invitations, :pod_invitations_quota,
             check:
               "used_count >= 0 AND (max_uses IS NULL OR (max_uses > 0 AND used_count <= max_uses))"
           )

    create unique_index(:pod_invitations, [:token_digest])
    create unique_index(:pod_invitations, [:code_digest])
    create index(:pod_invitations, [:invited_email])

    create index(:human_users, ["lower(email)"],
             where: "email IS NOT NULL",
             name: :human_users_cross_pod_email_idx
           )

    create index(:principal_external_identities, [:provider, :external_id],
             where: "provider = 'email'",
             name: :principal_external_identities_cross_pod_email_idx
           )

    flush()
    Ankole.CredentialUpgrade.connect_oidc_evidence!(repo())
    migrate_local_credentials!()
    migrate_lark_aliases!()
    release_departed_contacts!()
    scaffold_pod_admins!()

    alter table(:browser_login_transactions) do
      remove :password_ticket
    end

    drop table(:human_user_local_credentials)
  end

  def down do
    raise Ecto.MigrationError,
      message: "Passwordless authentication requires a database backup to roll back."
  end

  defp migrate_local_credentials! do
    %{rows: rows} =
      repo().query!("""
      SELECT h.tenant_id, h.principal_uid, lower(btrim(h.email))
      FROM human_user_local_credentials c JOIN human_users h
        ON h.tenant_id = c.tenant_id AND h.principal_uid = c.principal_uid
      JOIN principals p ON p.tenant_id = h.tenant_id AND p.uid = h.principal_uid
      WHERE h.email IS NOT NULL AND NOT (#{Ankole.CredentialUpgrade.offboarded_sql()})
      """)

    for [tenant_id, uid, email] <- rows do
      repo().query!(
        """
        INSERT INTO principal_site_credentials
          (id, tenant_id, principal_uid, kind, provider, identifier, verified_email, inserted_at, updated_at)
        VALUES ($1, $2, $3, 'otp', 'email_otp', $4, $4, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        """,
        [uuid(), tenant_id, uid, email]
      )
    end

    # Provider IDs are saved in configuration and OIDC authorization records.
    %{rows: providers} =
      repo().query!("""
      SELECT DISTINCT tenant_id, activation->>'provider_id'
      FROM app_configurations CROSS JOIN LATERAL jsonb_array_elements(value->'value') activation
      WHERE key = 'principals.identity_providers.active' AND activation->>'adapter_id' = 'local'
      """)

    for [tenant_id, provider] <- providers, is_binary(provider) do
      repo().query!(
        """
        UPDATE oidc_clients SET allowed_identity_provider_ids = ARRAY(
          SELECT DISTINCT CASE WHEN x = $1 THEN 'email_otp' ELSE x END
          FROM unnest(allowed_identity_provider_ids) x)
        WHERE $1 = ANY(allowed_identity_provider_ids) AND tenant_id = $2
        """,
        [provider, tenant_id]
      )

      repo().query!(
        "UPDATE oidc_sessions SET provider_id = 'email_otp' WHERE provider_id = $1 AND tenant_id = $2",
        [
          provider,
          tenant_id
        ]
      )

      repo().query!(
        """
        UPDATE browser_authentications auth SET provider_id = 'email_otp',
          verified_email = lower(btrim(h.email)), amr = ARRAY['pwd'],
          revoked_at = COALESCE(auth.revoked_at, CURRENT_TIMESTAMP)
        FROM human_users h
        WHERE auth.provider_id = $1 AND auth.tenant_id = $2 AND auth.tenant_id = h.tenant_id
          AND auth.subject_id = h.principal_uid
        """,
        [provider, tenant_id]
      )
    end

    repo().query!(
      "DELETE FROM app_configurations WHERE key LIKE 'principals.identity_providers.local.%' OR key LIKE 'principals.local_password.%'"
    )
  end

  defp release_departed_contacts! do
    %{rows: rows} =
      repo().query!("""
      SELECT p.tenant_id, p.uid, p.access_version, array_remove(array_agg(DISTINCT claims.identifier), NULL)
      FROM principals p LEFT JOIN LATERAL (
        SELECT 'email:' || lower(btrim(h.email)) AS identifier FROM human_users h
          WHERE h.tenant_id = p.tenant_id AND h.principal_uid = p.uid AND h.email IS NOT NULL
        UNION SELECT 'phone:' || h.mobile FROM human_users h
          WHERE h.tenant_id = p.tenant_id AND h.principal_uid = p.uid AND h.mobile IS NOT NULL
        UNION SELECT 'email:' || lower(btrim(i.external_id)) FROM principal_external_identities i
          WHERE i.tenant_id = p.tenant_id AND i.principal_uid = p.uid AND i.provider = 'email'
      ) claims ON true
      WHERE p.type = 'human' AND (#{Ankole.CredentialUpgrade.offboarded_sql()})
      GROUP BY p.tenant_id, p.uid, p.access_version
      """)

    for [tenant_id, uid, version, identifiers] <- rows do
      if identifiers != [] do
        repo().query!(
          """
          INSERT INTO human_access_events
            (id, tenant_id, principal_uid, operation_id, source, action, reason, previous_status,
             status, access_version, released_identifiers, inserted_at)
          VALUES ($1, $2, $3, 'passwordless-migration', 'migration', 'release', 'offboarded',
            'disabled', 'disabled', $4, $5, CURRENT_TIMESTAMP)
          """,
          [uuid(), tenant_id, uid, version, identifiers]
        )
      end

      repo().query!(
        "DELETE FROM principal_site_credentials WHERE tenant_id = $1 AND principal_uid = $2",
        [tenant_id, uid]
      )

      repo().query!(
        "DELETE FROM principal_external_identities WHERE tenant_id = $1 AND principal_uid = $2 AND provider = 'email'",
        [tenant_id, uid]
      )

      repo().query!(
        "UPDATE human_users SET email = NULL, mobile = NULL WHERE tenant_id = $1 AND principal_uid = $2",
        [tenant_id, uid]
      )
    end
  end

  defp migrate_lark_aliases! do
    %{rows: rows} =
      repo().query!("""
      SELECT i.id, i.tenant_id, i.principal_uid, lower(btrim(i.external_id))
      FROM principal_external_identities i
      WHERE i.external_id LIKE '%@%' AND (i.provider = 'lark' OR EXISTS (
        SELECT 1 FROM app_configurations c,
          LATERAL jsonb_array_elements(c.value->'value') entry
        WHERE c.tenant_id = i.tenant_id AND c.key = 'principals.identity_providers.active'
          AND entry->>'adapter_id' = 'lark' AND entry->>'provider_id' = i.provider))
        AND ((EXISTS (
          SELECT 1 FROM principals p WHERE p.tenant_id = i.tenant_id AND p.uid = i.principal_uid
            AND (#{Ankole.CredentialUpgrade.offboarded_sql()}))) OR EXISTS (
          SELECT 1 FROM principal_external_identities stable
          WHERE stable.tenant_id = i.tenant_id AND stable.principal_uid = i.principal_uid
            AND stable.provider = i.provider AND stable.external_id NOT LIKE '%@%'))
      """)

    for [id, tenant_id, uid, email] <- rows do
      repo().query!(
        """
        INSERT INTO principal_external_identities
          (id, tenant_id, principal_uid, provider, external_id, metadata, inserted_at, updated_at)
        VALUES ($1, $2, $3, 'email', $4, '{"origin":"directory"}', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        ON CONFLICT DO NOTHING
        """,
        [uuid(), tenant_id, uid, email]
      )

      repo().query!(
        "DELETE FROM principal_external_identities WHERE id = $1 AND tenant_id = $2",
        [id, tenant_id]
      )
    end
  end

  defp scaffold_pod_admins! do
    %{rows: tenants} =
      repo().query!("SELECT id, slug FROM tenants WHERE deleting_at IS NULL ORDER BY id")

    for [tenant_id, slug] <- tenants do
      group_id = uuid()

      repo().query!(
        """
        INSERT INTO principal_groups (id, tenant_id, name, display_name, kind, built_in, inserted_at, updated_at)
        VALUES ($1, $2, 'pod_admin', 'Pod Administrators', 'static', true, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        ON CONFLICT (tenant_id, name) DO NOTHING
        """,
        [group_id, tenant_id]
      )

      %{rows: [[group_id]]} =
        repo().query!(
          "SELECT id FROM principal_groups WHERE tenant_id = $1 AND name = 'pod_admin'",
          [tenant_id]
        )

      for action <- ["read", "update", "delete", "reset", "decrypt", "sync"] do
        repo().query!(
          """
          INSERT INTO permission_grants (id, tenant_id, group_id, resource_pattern, action, condition, inserted_at, updated_at)
          VALUES ($1, $2, $3, 'tenant_console:**', $4, 'true', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
          ON CONFLICT DO NOTHING
          """,
          [uuid(), tenant_id, group_id, action]
        )
      end

      %{rows: admins} =
        repo().query!(
          """
          SELECT p.uid FROM principals p
          WHERE p.tenant_id = $1 AND p.type = 'human' AND p.status = 'active' AND p.membership = 'member'
            AND (EXISTS (
              SELECT 1 FROM principal_group_memberships m JOIN principal_groups g
                ON g.tenant_id = m.tenant_id AND g.id = m.group_id
              WHERE m.tenant_id = p.tenant_id AND m.principal_uid = p.uid AND g.name = 'siteadmin' AND g.built_in
            ) OR ((SELECT count(*) FROM principals h WHERE h.tenant_id = p.tenant_id AND h.type = 'human') = 1
              AND NOT EXISTS (SELECT 1 FROM identity_directory_states d WHERE d.tenant_id = p.tenant_id)))
          """,
          [tenant_id]
        )

      for [uid] <- admins do
        repo().query!(
          """
          INSERT INTO principal_group_memberships (tenant_id, group_id, principal_uid, inserted_at)
          VALUES ($1, $2, $3, CURRENT_TIMESTAMP) ON CONFLICT DO NOTHING
          """,
          [tenant_id, group_id, uid]
        )
      end

      if admins == [],
        do: IO.puts("Assign a Pod administrator for #{slug} (#{Ecto.UUID.load!(tenant_id)}).")
    end
  end

  defp uuid, do: Ecto.UUID.dump!(Ankole.Ecto.UUIDv7.autogenerate())
end
