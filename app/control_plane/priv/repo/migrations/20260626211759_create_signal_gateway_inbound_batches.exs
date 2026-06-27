defmodule Ankole.Repo.Migrations.CreateSignalGatewayInboundBatches do
  use Ecto.Migration

  def change do
    create table(:signal_gateway_inbound_batches, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :agent_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          null: false

      add :binding_name, :text, null: false
      add :session_id, :text, null: false

      add :signal_channel_id,
          references(:signal_channels, column: :id, type: :text, on_delete: :delete_all),
          null: false

      add :provider_thread_id, :text, null: false, default: ""
      add :batch_state, :text, null: false, default: "open"
      add :mode, :text, null: false, default: "neutral"
      add :policy, :text, null: false
      add :requester_sender_key, :text
      add :entries, :map, null: false, default: fragment("'[]'::jsonb")
      add :available_at, :utc_datetime_usec, null: false
      add :hard_cap_at, :utc_datetime_usec
      add :batch_revision, :integer, null: false, default: 0
      add :outcome, :text
      add :finalized_at, :utc_datetime_usec
      add :actor_input_id, :uuid

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :signal_gateway_inbound_batches,
             [:agent_uid, :binding_name, :signal_channel_id, :provider_thread_id],
             where: "batch_state = 'open'",
             name: :signal_gateway_inbound_batches_open_index
           )

    create index(:signal_gateway_inbound_batches, [:batch_state, :available_at],
             name: :signal_gateway_inbound_batches_due_index
           )

    create index(
             :signal_gateway_inbound_batches,
             [:agent_uid, :binding_name, :signal_channel_id],
             name: :signal_gateway_inbound_batches_entry_lookup_index
           )

    create constraint(:signal_gateway_inbound_batches, :inbound_batches_entries_array,
             check: "jsonb_typeof(entries) = 'array'"
           )

    create constraint(:signal_gateway_inbound_batches, :inbound_batches_state_check,
             check: "batch_state IN ('open', 'finalized', 'canceled')"
           )

    create constraint(:signal_gateway_inbound_batches, :inbound_batches_mode_check,
             check: "mode IN ('neutral', 'addressed')"
           )

    create constraint(:signal_gateway_inbound_batches, :inbound_batches_policy_check,
             check: "policy IN ('ignore', 'record_only', 'may_intervene')"
           )

    create constraint(:signal_gateway_inbound_batches, :inbound_batches_outcome_check,
             check:
               "outcome IS NULL OR outcome IN ('addressed', 'ambient', 'no_actor_input', 'duplicate_consumed', 'canceled')"
           )
  end
end
