defmodule Ankole.Repo.Migrations.AddArtifactProviderItemId do
  use Ecto.Migration

  def change do
    alter table(:ai_gateway_artifacts) do
      add :provider_item_id, :text
    end

    create index(:ai_gateway_artifacts, [:subject_uid, :provider_item_id],
             name: :ai_gateway_artifacts_provider_item_index,
             where: "provider_item_id IS NOT NULL"
           )
  end
end
