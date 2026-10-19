defmodule Ankole.Repo.Migrations.LinkPageConversations do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      add :page_id, :uuid
    end

    create index(:conversations, [:tenant_id, :page_id, :last_activity_at])

    create constraint(:conversations, :conversations_page_origin_check,
             check: "page_id IS NULL OR kind = 'native'"
           )

    execute(
      "ALTER TABLE conversations ADD CONSTRAINT conversations_page_fkey " <>
        "FOREIGN KEY (tenant_id, page_id) REFERENCES pages (tenant_id, id) " <>
        "ON DELETE SET NULL (page_id)",
      "ALTER TABLE conversations DROP CONSTRAINT conversations_page_fkey"
    )
  end
end
