defmodule Ankole.Repo.Migrations.ProtectPendingOutboxAttachments do
  use Ecto.Migration

  def change do
    create index(:signal_gateway_outbox_entries, ["payload jsonb_path_ops"],
             name: :outbox_pending_attachments_index,
             using: :gin,
             where: "status <> 'succeeded'"
           )
  end
end
