defmodule Ankole.Repo.Migrations.CreateSignalGatewayWebhookEndpoints do
  use Ecto.Migration

  def change do
    create table(:signal_gateway_webhook_endpoints, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :token_digest, :text, null: false

      add :agent_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          null: false

      add :binding_name, :text, null: false
      add :session_id, :text, null: false
      add :signal_channel_id, :text
      add :provider_thread_id, :text
      add :source_actor_event_id, references(:actor_events, type: :uuid, on_delete: :nilify_all)
      add :source_entry_id, :text
      add :source_provenance, :map, null: false, default: %{}
      add :label, :text, null: false
      add :mode, :text, null: false
      add :status, :text, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :fired_at, :utc_datetime_usec
      add :cancelled_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:signal_gateway_webhook_endpoints, [:token_digest],
             name: :signal_gateway_webhook_endpoints_token_digest_index
           )

    create index(
             :signal_gateway_webhook_endpoints,
             [:agent_uid, :session_id, :status, :expires_at],
             name: :signal_gateway_webhook_endpoints_actor_status_index
           )

    create index(:signal_gateway_webhook_endpoints, [:status, :expires_at],
             name: :signal_gateway_webhook_endpoints_expiry_index,
             where: "status IN ('armed', 'active')"
           )

    create index(:signal_gateway_webhook_endpoints, [:source_actor_event_id],
             name: :signal_gateway_webhook_endpoints_source_event_index,
             where: "source_actor_event_id IS NOT NULL"
           )

    create constraint(
             :signal_gateway_webhook_endpoints,
             :signal_gateway_webhook_endpoints_mode_check,
             check: "mode IN ('one_shot', 'standing')"
           )

    create constraint(
             :signal_gateway_webhook_endpoints,
             :signal_gateway_webhook_endpoints_status_check,
             check:
               "(mode = 'one_shot' AND status IN ('armed', 'fired', 'expired', 'cancelled')) OR " <>
                 "(mode = 'standing' AND status IN ('active', 'expired', 'cancelled'))"
           )

    create constraint(
             :signal_gateway_webhook_endpoints,
             :signal_gateway_webhook_endpoints_token_digest_length,
             check: "length(token_digest) = 43"
           )

    create constraint(
             :signal_gateway_webhook_endpoints,
             :signal_gateway_webhook_endpoints_label_present,
             check: "length(btrim(label)) > 0"
           )

    create constraint(
             :signal_gateway_webhook_endpoints,
             :signal_gateway_webhook_endpoints_binding_name_present,
             check: "length(btrim(binding_name)) > 0"
           )

    create constraint(
             :signal_gateway_webhook_endpoints,
             :signal_gateway_webhook_endpoints_session_id_present,
             check: "length(btrim(session_id)) > 0"
           )

    create constraint(
             :signal_gateway_webhook_endpoints,
             :signal_gateway_webhook_endpoints_source_provenance_object,
             check: "jsonb_typeof(source_provenance) = 'object'"
           )

    execute(
      "COMMENT ON TABLE signal_gateway_webhook_endpoints IS " <>
        "'Capability URLs that route external task receipts to one Agent session.'"
    )
  end
end
