defmodule Ankole.Repo.Migrations.IndexMediaJobsExpiresAt do
  use Ecto.Migration

  def change do
    create_if_not_exists index(:ai_gateway_media_jobs, [:tenant_id, :expires_at])
  end
end
