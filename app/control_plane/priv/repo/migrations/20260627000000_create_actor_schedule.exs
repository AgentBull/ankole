defmodule Ankole.Repo.Migrations.CreateActorSchedule do
  use Ecto.Migration

  def up do
    create table(:actor_cron_schedules, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :status, :text, null: false

      add :agent_uid, references(:principals, column: :uid, type: :text, on_delete: :delete_all),
        null: false

      add :session_id, :text, null: false
      add :binding_name, :text, null: false
      add :name, :text
      add :schedule, :map, null: false
      add :timezone, :text, null: false
      add :payload, :map, null: false
      add :delivery, :map
      add :next_fire_at, :utc_datetime_usec
      add :last_fire_at, :utc_datetime_usec
      add :idempotency_key, :text, null: false
      add :created_by, :map, null: false, default: %{}
      add :failure_policy, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:actor_cron_schedules, [:agent_uid, :session_id, :idempotency_key],
             name: :actor_cron_schedules_idempotency_index
           )

    create unique_index(:actor_cron_schedules, [:agent_uid, :name],
             name: :actor_cron_schedules_agent_name_index,
             where: "status != 'deleted' AND name IS NOT NULL"
           )

    create index(:actor_cron_schedules, [:status, :next_fire_at],
             name: :actor_cron_schedules_due_index
           )

    create index(:actor_cron_schedules, [:agent_uid, :session_id, :status],
             name: :actor_cron_schedules_actor_status_index
           )

    create constraint(:actor_cron_schedules, :actor_cron_schedules_status_check,
             check: "status IN ('active', 'paused', 'deleted', 'failed')"
           )

    create constraint(:actor_cron_schedules, :actor_cron_schedules_timezone_present,
             check: "length(btrim(timezone)) > 0"
           )

    create constraint(:actor_cron_schedules, :actor_cron_schedules_idempotency_key_present,
             check: "length(btrim(idempotency_key)) > 0"
           )

    create constraint(:actor_cron_schedules, :actor_cron_schedules_schedule_object,
             check: "jsonb_typeof(schedule) = 'object'"
           )

    create constraint(:actor_cron_schedules, :actor_cron_schedules_payload_object,
             check: "jsonb_typeof(payload) = 'object'"
           )

    create constraint(:actor_cron_schedules, :actor_cron_schedules_delivery_object,
             check: "delivery IS NULL OR jsonb_typeof(delivery) = 'object'"
           )

    create constraint(:actor_cron_schedules, :actor_cron_schedules_created_by_object,
             check: "jsonb_typeof(created_by) = 'object'"
           )

    create constraint(:actor_cron_schedules, :actor_cron_schedules_failure_policy_object,
             check: "jsonb_typeof(failure_policy) = 'object'"
           )

    create table(:actor_scheduled_events, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :kind, :text, null: false
      add :status, :text, null: false

      add :agent_uid, references(:principals, column: :uid, type: :text, on_delete: :delete_all),
        null: false

      add :session_id, :text, null: false
      add :binding_name, :text, null: false
      add :due_at, :utc_datetime_usec, null: false
      add :timezone, :text, null: false
      add :requested_at, :utc_datetime_usec, null: false
      add :idempotency_key, :text, null: false

      add :cron_schedule_id,
          references(:actor_cron_schedules, type: :uuid, on_delete: :nilify_all)

      add :cron_fire_slot_at, :utc_datetime_usec
      add :tool_call_id, :text
      add :source_llm_turn_id, :uuid
      add :source_actor_input_id, :uuid
      add :signal_channel_id, :text
      add :provider_thread_id, :text
      add :provider_entry_id, :text
      add :source_provenance, :map, null: false, default: %{}
      add :wake_payload, :map, null: false, default: %{}
      add :oban_job_id, :bigint
      add :actor_input_id, :uuid
      add :fire_attempts, :integer, null: false, default: 0
      add :fire_claimed_at, :utc_datetime_usec
      add :fired_at, :utc_datetime_usec
      add :cancelled_at, :utc_datetime_usec
      add :last_fire_error, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :actor_scheduled_events,
             [:kind, :agent_uid, :session_id, :idempotency_key],
             name: :actor_scheduled_events_idempotency_index
           )

    create unique_index(:actor_scheduled_events, [:cron_schedule_id, :cron_fire_slot_at],
             name: :actor_scheduled_events_cron_slot_index,
             where: "cron_schedule_id IS NOT NULL"
           )

    create index(:actor_scheduled_events, [:status, :due_at],
             name: :actor_scheduled_events_due_index
           )

    create index(:actor_scheduled_events, [:agent_uid, :session_id, :status, :due_at],
             name: :actor_scheduled_events_actor_due_index
           )

    create index(:actor_scheduled_events, [:actor_input_id],
             name: :actor_scheduled_events_actor_input_index
           )

    create index(:actor_scheduled_events, [:oban_job_id],
             name: :actor_scheduled_events_oban_job_index
           )

    create constraint(:actor_scheduled_events, :actor_scheduled_events_kind_check,
             check: "kind IN ('check_back_later', 'cron_fire')"
           )

    create constraint(:actor_scheduled_events, :actor_scheduled_events_status_check,
             check: "status IN ('scheduled', 'firing', 'fired', 'cancelled', 'failed')"
           )

    create constraint(:actor_scheduled_events, :actor_scheduled_events_timezone_present,
             check: "length(btrim(timezone)) > 0"
           )

    create constraint(:actor_scheduled_events, :actor_scheduled_events_idempotency_key_present,
             check: "length(btrim(idempotency_key)) > 0"
           )

    create constraint(:actor_scheduled_events, :actor_scheduled_events_source_provenance_object,
             check: "jsonb_typeof(source_provenance) = 'object'"
           )

    create constraint(:actor_scheduled_events, :actor_scheduled_events_wake_payload_object,
             check: "jsonb_typeof(wake_payload) = 'object'"
           )

    create constraint(:actor_scheduled_events, :actor_scheduled_events_last_fire_error_object,
             check: "jsonb_typeof(last_fire_error) = 'object'"
           )

    execute(
      "COMMENT ON TABLE actor_cron_schedules IS 'Recurring actor schedule definitions owned by Ankole.'"
    )

    execute(
      "COMMENT ON TABLE actor_scheduled_events IS 'Concrete pending or terminal actor schedule fires.'"
    )
  end

  def down do
    drop table(:actor_scheduled_events)
    drop table(:actor_cron_schedules)
  end
end
