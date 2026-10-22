defmodule Ankole.Repo.Migrations.ConstrainOidcSessionFacts do
  use Ecto.Migration

  def change do
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
end
