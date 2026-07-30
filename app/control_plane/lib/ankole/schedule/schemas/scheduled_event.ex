defmodule Ankole.Schedule.Schemas.ScheduledEvent do
  @moduledoc """
  Concrete fire attempt shared by one-shot checkbacks and cron schedules.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Principals.Principal
  alias Ankole.AutomationJobs.Schemas.Job, as: AutomationJob
  alias Ankole.AutomationJobs.Schemas.Run, as: AutomationJobRun
  alias Ankole.Schedule.Schemas.CronSchedule
  alias Ankole.Ecto.JSONPayload
  alias Ankole.TimeZone

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @kinds ~w(check_back_later cron_fire)
  @statuses ~w(scheduled firing fired cancelled failed)

  schema "actor_scheduled_events" do
    field :kind, :string
    field :status, :string, default: "scheduled"

    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey

    field :session_id, :string
    field :binding_name, :string
    field :due_at, :utc_datetime_usec
    field :timezone, :string
    field :requested_at, :utc_datetime_usec
    field :idempotency_key, :string

    belongs_to :cron_schedule, CronSchedule, type: :binary_id
    belongs_to :automation_job, AutomationJob, type: :id
    belongs_to :automation_job_run, AutomationJobRun, type: :id

    field :cron_fire_slot_at, :utc_datetime_usec
    field :tool_call_id, :string
    field :source_actor_event_id, Ecto.UUID
    field :signal_channel_id, :string
    field :provider_thread_id, :string
    field :source_entry_id, :string
    field :source_provenance, :map, default: %{}
    field :wake_payload, :map, default: %{}
    field :oban_job_id, :integer
    field :actor_event_id, Ecto.UUID
    # When the schedule originates from an AI/tool message, record the stored
    # ai_gateway_messages.id so the origin can be traced deterministically.
    field :origin_ai_message_id, Ecto.UUID
    field :fire_attempts, :integer, default: 0
    field :fire_claimed_at, :utc_datetime_usec
    field :fired_at, :utc_datetime_usec
    field :cancelled_at, :utc_datetime_usec
    field :last_fire_error, :map, default: %{}

    timestamps()
  end

  @doc """
  Builds a changeset for scheduled event rows.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :kind,
      :status,
      :agent_uid,
      :session_id,
      :binding_name,
      :due_at,
      :timezone,
      :requested_at,
      :idempotency_key,
      :cron_schedule_id,
      :automation_job_id,
      :automation_job_run_id,
      :cron_fire_slot_at,
      :tool_call_id,
      :source_actor_event_id,
      :signal_channel_id,
      :provider_thread_id,
      :source_entry_id,
      :source_provenance,
      :wake_payload,
      :oban_job_id,
      :actor_event_id,
      :origin_ai_message_id,
      :fire_attempts,
      :fire_claimed_at,
      :fired_at,
      :cancelled_at,
      :last_fire_error
    ])
    |> normalize_blank([
      :kind,
      :status,
      :agent_uid,
      :session_id,
      :binding_name,
      :timezone,
      :idempotency_key,
      :tool_call_id,
      :signal_channel_id,
      :provider_thread_id,
      :source_entry_id
    ])
    |> validate_required([
      :kind,
      :status,
      :agent_uid,
      :session_id,
      :binding_name,
      :due_at,
      :timezone,
      :requested_at,
      :idempotency_key,
      :source_provenance,
      :wake_payload,
      :fire_attempts,
      :last_fire_error
    ])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:fire_attempts, greater_than_or_equal_to: 0)
    |> validate_timezone(:timezone)
    |> JSONPayload.validate_map(:source_provenance)
    |> JSONPayload.validate_map(:wake_payload)
    |> JSONPayload.validate_map(:last_fire_error)
    |> foreign_key_constraint(:agent_uid)
    |> foreign_key_constraint(:cron_schedule_id)
    |> foreign_key_constraint(:automation_job_id)
    |> foreign_key_constraint(:automation_job_run_id)
    |> foreign_key_constraint(:source_actor_event_id)
    |> foreign_key_constraint(:actor_event_id)
    |> foreign_key_constraint(:origin_ai_message_id)
    |> unique_constraint([:kind, :agent_uid, :session_id, :idempotency_key],
      name: :actor_scheduled_events_idempotency_index
    )
    |> unique_constraint([:cron_schedule_id, :cron_fire_slot_at],
      name: :actor_scheduled_events_cron_slot_index
    )
    |> unique_constraint(:cron_schedule_id,
      name: :actor_scheduled_events_one_live_recurring_index
    )
    |> check_constraint(:kind, name: :actor_scheduled_events_kind_check)
    |> check_constraint(:status, name: :actor_scheduled_events_status_check)
    |> check_constraint(:timezone, name: :actor_scheduled_events_timezone_present)
    |> check_constraint(:idempotency_key,
      name: :actor_scheduled_events_idempotency_key_present
    )
    |> check_constraint(:source_provenance,
      name: :actor_scheduled_events_source_provenance_object
    )
    |> check_constraint(:wake_payload, name: :actor_scheduled_events_wake_payload_object)
    |> check_constraint(:last_fire_error,
      name: :actor_scheduled_events_last_fire_error_object
    )
  end

  defp validate_timezone(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case TimeZone.validate(value) do
        {:ok, _timezone} -> []
        {:error, reason} -> [{field, "is not a valid timezone: #{inspect(reason)}"}]
      end
    end)
  end
end
