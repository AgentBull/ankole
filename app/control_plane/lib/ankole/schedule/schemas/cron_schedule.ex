defmodule Ankole.Schedule.Schemas.CronSchedule do
  @moduledoc """
  Durable recurring schedule definition.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Principals.Principal
  alias Ankole.Ecto.JSONPayload
  alias Ankole.TimeZone

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @statuses ~w(active paused deleted)

  schema "actor_cron_schedules" do
    field :status, :string, default: "active"

    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey

    field :session_id, :string
    field :binding_name, :string
    field :name, :string
    field :schedule, :map, default: %{}
    field :timezone, :string
    field :payload, :map, default: %{}
    field :delivery, :map
    field :next_fire_at, :utc_datetime_usec
    field :last_fire_at, :utc_datetime_usec
    field :idempotency_key, :string
    field :created_by, :map, default: %{}
    timestamps()
  end

  @doc """
  Builds a changeset for cron schedule rows.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(schedule, attrs) do
    schedule
    |> cast(attrs, [
      :status,
      :agent_uid,
      :session_id,
      :binding_name,
      :name,
      :schedule,
      :timezone,
      :payload,
      :delivery,
      :next_fire_at,
      :last_fire_at,
      :idempotency_key,
      :created_by
    ])
    |> normalize_blank([
      :status,
      :agent_uid,
      :session_id,
      :binding_name,
      :name,
      :timezone,
      :idempotency_key
    ])
    |> validate_required([
      :status,
      :agent_uid,
      :session_id,
      :binding_name,
      :name,
      :schedule,
      :timezone,
      :payload,
      :idempotency_key,
      :created_by
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_timezone(:timezone)
    |> JSONPayload.validate_map(:schedule)
    |> JSONPayload.validate_map(:payload)
    |> validate_nullable_map(:delivery)
    |> JSONPayload.validate_map(:created_by)
    |> foreign_key_constraint(:agent_uid)
    |> unique_constraint([:agent_uid, :session_id, :idempotency_key],
      name: :actor_cron_schedules_idempotency_index
    )
    |> unique_constraint([:agent_uid, :session_id, :name],
      name: :actor_cron_schedules_agent_name_index
    )
    |> check_constraint(:status, name: :actor_cron_schedules_status_check)
    |> check_constraint(:timezone, name: :actor_cron_schedules_timezone_present)
    |> check_constraint(:name, name: :actor_cron_schedules_name_present)
    |> check_constraint(:idempotency_key,
      name: :actor_cron_schedules_idempotency_key_present
    )
    |> check_constraint(:schedule, name: :actor_cron_schedules_schedule_object)
    |> check_constraint(:payload, name: :actor_cron_schedules_payload_object)
    |> check_constraint(:delivery, name: :actor_cron_schedules_delivery_object)
    |> check_constraint(:created_by, name: :actor_cron_schedules_created_by_object)
  end

  defp validate_nullable_map(changeset, field) do
    case get_change(changeset, field, get_field(changeset, field)) do
      nil -> changeset
      _value -> JSONPayload.validate_map(changeset, field)
    end
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
