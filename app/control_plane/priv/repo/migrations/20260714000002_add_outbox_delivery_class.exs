defmodule Ankole.Repo.Migrations.AddOutboxDeliveryClass do
  use Ecto.Migration

  def change do
    alter table(:signal_gateway_outbox_entries) do
      add :delivery_class, :text, null: false, default: "generic"
    end

    create index(:signal_gateway_outbox_entries, [:delivery_class, :status, :next_attempt_at])

    create constraint(
             :signal_gateway_outbox_entries,
             :signal_gateway_outbox_entries_delivery_class_check,
             check: "delivery_class IN ('generic', 'durable_ai_reply')"
           )
  end
end
