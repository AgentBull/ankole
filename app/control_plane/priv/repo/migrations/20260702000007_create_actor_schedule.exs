defmodule Ankole.Repo.Migrations.CreateActorSchedule do
  # Actor scheduling stores recurring definitions and concrete fire attempts.
  #
  # actor_event_id records the work item appended by a fire attempt, source_actor_event_id
  # records the triggering actor event, and origin_ai_message_id links schedules created
  # from AI/tool output back to the stored message that requested them.
  use Ecto.Migration

  def up do
    # Recurring schedule definitions own future slots; fire attempts are stored separately.
    create table(:actor_cron_schedules, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :status, :text, null: false

      add :agent_uid, references(:principals, column: :uid, type: :text, on_delete: :delete_all),
        null: false

      add :session_id, :text, null: false
      add :binding_name, :text, null: false
      add :name, :text, null: false
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

    create unique_index(:actor_cron_schedules, [:agent_uid, :session_id, :name],
             name: :actor_cron_schedules_agent_name_index,
             where: "status != 'deleted'"
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

    create constraint(:actor_cron_schedules, :actor_cron_schedules_name_present,
             check: "length(btrim(name)) > 0"
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

    # Concrete fire attempts survive terminal state for audit, retry, and idempotency checks.
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
      add :source_actor_event_id, references(:actor_events, type: :uuid, on_delete: :nilify_all)
      add :signal_channel_id, :text
      add :provider_thread_id, :text
      add :source_entry_id, :text
      add :source_provenance, :map, null: false, default: %{}
      add :wake_payload, :map, null: false, default: %{}
      add :oban_job_id, :bigint
      add :actor_event_id, references(:actor_events, type: :uuid, on_delete: :nilify_all)
      # Stored message that requested the schedule when it came from AI/tool output.
      add :origin_ai_message_id,
          references(:ai_gateway_messages, type: :uuid, on_delete: :nilify_all)

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

    create index(:actor_scheduled_events, [:actor_event_id],
             name: :actor_scheduled_events_actor_event_index
           )

    create index(:actor_scheduled_events, [:source_actor_event_id],
             name: :actor_scheduled_events_source_actor_event_index,
             where: "source_actor_event_id IS NOT NULL"
           )

    create index(:actor_scheduled_events, [:origin_ai_message_id],
             name: :actor_scheduled_events_origin_ai_message_index,
             where: "origin_ai_message_id IS NOT NULL"
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
