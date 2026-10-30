defmodule Ankole.Repo.Migrations.UnifyBrowserAuthenticationScope do
  use Ecto.Migration

  def up do
    drop constraint(:browser_authentications, :browser_authentications_subject_scope)
    execute "DROP INDEX browser_authentications_subject_index"

    reset_sessions()

    alter table(:browser_authentications) do
      add :scope, :text, null: false
      remove :purpose
      remove :console_authenticated
    end

    execute """
    CREATE UNIQUE INDEX browser_authentications_subject_index
    ON browser_authentications (browser_id, provider_id, subject_id, scope, tenant_id)
    NULLS NOT DISTINCT
    """

    create constraint(:browser_authentications, :browser_authentications_subject_scope,
             check:
               "(scope = 'site' AND tenant_id IS NULL) OR (scope = 'tenant' AND tenant_id IS NOT NULL)"
           )

    drop constraint(:browser_oidc_states, :browser_oidc_states_purpose)
    drop constraint(:browser_oidc_states, :browser_oidc_states_mode)
    drop constraint(:browser_oidc_states, :browser_oidc_states_oauth_request)

    alter table(:browser_oidc_states) do
      remove :purpose
      remove :mode
    end
  end

  def down do
    drop constraint(:browser_authentications, :browser_authentications_subject_scope)
    execute "DROP INDEX browser_authentications_subject_index"

    reset_sessions()

    alter table(:browser_authentications) do
      add :purpose, :text, null: false
      add :console_authenticated, :boolean, null: false, default: false
      remove :scope
    end

    execute """
    CREATE UNIQUE INDEX browser_authentications_subject_index
    ON browser_authentications (browser_id, provider_id, subject_id, purpose, tenant_id)
    NULLS NOT DISTINCT
    """

    create constraint(:browser_authentications, :browser_authentications_subject_scope,
             check:
               "(purpose = 'site' AND tenant_id IS NULL) OR (purpose IN ('console', 'oauth', 'pod') AND tenant_id IS NOT NULL)"
           )

    alter table(:browser_oidc_states) do
      add :purpose, :text, null: false
      add :mode, :text, null: false, default: "replace"
    end

    create constraint(:browser_oidc_states, :browser_oidc_states_purpose,
             check: "purpose IN ('console', 'oauth', 'pod')"
           )

    create constraint(:browser_oidc_states, :browser_oidc_states_mode,
             check: "mode IN ('replace', 'add')"
           )

    create constraint(:browser_oidc_states, :browser_oidc_states_oauth_request,
             check: "(purpose = 'oauth') = (oauth_request_id IS NOT NULL)"
           )
  end

  defp reset_sessions do
    # Pre-release authentication changes require a fresh login. Foreign keys
    # remove credentials, Pod proofs, and pending login/logout flows with their sessions.
    execute "DELETE FROM oidc_sessions"
    execute "DELETE FROM browser_sessions"
  end
end
