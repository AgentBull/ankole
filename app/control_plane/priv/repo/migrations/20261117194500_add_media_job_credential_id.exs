defmodule Ankole.Repo.Migrations.AddMediaJobCredentialId do
  use Ecto.Migration

  def change do
    alter table(:ai_gateway_media_jobs) do
      add(:credential_id, :text)
    end
  end
end
