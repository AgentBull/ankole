defmodule Ankole.Repo.Migrations.ConstrainInboundBatchRevision do
  use Ecto.Migration

  def change do
    create constraint(:conversation_inbound_batches, :inbound_batches_revision_non_negative,
             check: "batch_revision >= 0"
           )
  end
end
