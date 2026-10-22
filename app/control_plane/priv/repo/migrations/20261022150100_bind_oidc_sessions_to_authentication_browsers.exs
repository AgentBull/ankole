defmodule Ankole.Repo.Migrations.BindOidcSessionsToAuthenticationBrowsers do
  use Ecto.Migration

  def up do
    create unique_index(:browser_authentications, [:browser_id, :id])
    execute("ALTER TABLE oidc_sessions DROP CONSTRAINT oidc_sessions_authentication_id_fkey")

    execute("""
    ALTER TABLE oidc_sessions ADD CONSTRAINT oidc_sessions_authentication_id_fkey
      FOREIGN KEY (browser_id, authentication_id)
      REFERENCES browser_authentications (browser_id, id)
      ON DELETE SET NULL (authentication_id)
    """)
  end

  def down do
    execute("ALTER TABLE oidc_sessions DROP CONSTRAINT oidc_sessions_authentication_id_fkey")

    execute("""
    ALTER TABLE oidc_sessions ADD CONSTRAINT oidc_sessions_authentication_id_fkey
      FOREIGN KEY (authentication_id) REFERENCES browser_authentications (id)
      ON DELETE SET NULL
    """)

    drop index(:browser_authentications, [:browser_id, :id])
  end
end
