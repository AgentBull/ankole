defmodule Ankole.Repo.Migrations.IndexOidcSessionExpiry do
  use Ecto.Migration

  def change do
    create index(:oidc_sessions, [:expires_at])
    create index(:oidc_sessions, [:browser_id])
  end
end
