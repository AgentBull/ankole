defmodule Ankole.Repo.Migrations.AddAmbientCuration do
  use Ecto.Migration

  def change do
    alter table(:signal_gateway_channels) do
      add :ambient_standing_orders, :text
      add :ambient_standing_orders_set_by, :text
      add :ambient_standing_orders_updated_at, :utc_datetime_usec
      add :ambient_judged_until, :utc_datetime_usec
    end

    alter table(:actor_events) do
      add :ambient_asked_source_entry_id, :text
    end

    create table(:signal_gateway_ambient_judgments, primary_key: false) do
      add :actor_event_id,
          references(:actor_events, type: :uuid, on_delete: :delete_all),
          primary_key: true

      add :agent_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          null: false

      add :signal_channel_id, :text, null: false
      add :decision, :text, null: false
      add :reason, :text, null: false, default: ""
      add :asked_by_source_entry_id, :text
      add :asked_by_state, :text
      add :judged_until, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:signal_gateway_ambient_judgments, [:signal_channel_id, :inserted_at],
             name: :signal_gateway_ambient_judgments_channel_index
           )

    create constraint(
             :signal_gateway_ambient_judgments,
             :signal_gateway_ambient_judgments_decision_check,
             check: "decision IN ('intervene', 'silent')"
           )

    create constraint(
             :signal_gateway_ambient_judgments,
             :signal_gateway_ambient_judgments_asked_by_state_check,
             check: "asked_by_state IS NULL OR asked_by_state IN ('accepted', 'degraded')"
           )
  end
end
