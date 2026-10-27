defmodule Ankole.Repo.Migrations.CaptureOidcCodeAuthenticationTime do
  use Ecto.Migration

  def up do
    alter table(:oidc_authorization_codes) do
      add :auth_time, :bigint
    end

    flush()

    execute("""
    UPDATE oidc_authorization_codes AS code
    SET auth_time = session.auth_time
    FROM oidc_sessions AS session
    WHERE code.session_id = session.id
      AND code.consumed_at IS NULL
      AND code.expires_at > now()
    """)
  end

  def down do
    alter table(:oidc_authorization_codes) do
      remove :auth_time
    end
  end
end
