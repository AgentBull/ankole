defmodule Ankole.Repo.Migrations.BindOidcCredentialsToSessions do
  use Ecto.Migration

  @session_tables [:oidc_authorization_codes, :oidc_refresh_tokens]

  def up do
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

    for table <- @session_tables do
      execute("ALTER TABLE #{table} DROP CONSTRAINT #{table}_session_id_fkey")

      execute("""
      ALTER TABLE #{table} ADD CONSTRAINT #{table}_session_id_fkey
        FOREIGN KEY (tenant_id, client_id, principal_uid, session_id)
        REFERENCES oidc_sessions (tenant_id, client_id, principal_uid, id)
        ON DELETE CASCADE
      """)
    end

    execute("ALTER TABLE oidc_refresh_tokens DROP CONSTRAINT oidc_refresh_tokens_family_id_fkey")

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

    drop(index(:oidc_refresh_token_families, [:tenant_id, :id]))
  end

  def down do
    execute(
      "ALTER TABLE oidc_authorization_codes DROP CONSTRAINT oidc_authorization_codes_family_id_fkey"
    )

    create(unique_index(:oidc_refresh_token_families, [:tenant_id, :id]))
    flush()
    execute("ALTER TABLE oidc_refresh_tokens DROP CONSTRAINT oidc_refresh_tokens_family_id_fkey")

    execute("""
    ALTER TABLE oidc_refresh_tokens ADD CONSTRAINT oidc_refresh_tokens_family_id_fkey
      FOREIGN KEY (tenant_id, family_id) REFERENCES oidc_refresh_token_families (tenant_id, id)
      ON DELETE CASCADE
    """)

    for table <- @session_tables do
      execute("ALTER TABLE #{table} DROP CONSTRAINT #{table}_session_id_fkey")

      execute("""
      ALTER TABLE #{table} ADD CONSTRAINT #{table}_session_id_fkey
        FOREIGN KEY (tenant_id, session_id) REFERENCES oidc_sessions (tenant_id, id)
        ON DELETE CASCADE
      """)
    end

    drop(
      index(:oidc_refresh_token_families, [:tenant_id, :session_id, :id],
        name: :oidc_refresh_token_families_session_binding_index
      )
    )

    drop(
      index(:oidc_sessions, [:tenant_id, :client_id, :principal_uid, :id],
        name: :oidc_sessions_credential_binding_index
      )
    )
  end
end
