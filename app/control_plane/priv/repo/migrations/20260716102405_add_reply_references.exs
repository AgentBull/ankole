defmodule Ankole.Repo.Migrations.AddReplyReferences do
  use Ecto.Migration

  def change do
    alter table(:signal_gateway_entries) do
      add :reply_to_source_entry_id, :text
    end

    alter table(:signal_gateway_inbound_batches) do
      add :reply_to_source_entry_id, :text
    end
  end
end
