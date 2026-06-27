defmodule Ankole.Schedule.Schemas.CronSchedule do
  @moduledoc """
  Durable recurring schedule definition.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.Principals.Principal
  alias Ankole.SignalsGateway.JsonPayload

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @statuses ~w(active paused deleted failed)

  schema "actor_cron_schedules" do
    field :status, :string, default: "active"

    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: :string

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
    field :failure_policy, :map, default: %{}

    timestamps()
  end

  @doc false
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
      :created_by,
      :failure_policy
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
    |> normalize_uid(:agent_uid)
    |> validate_required([
      :status,
      :agent_uid,
      :session_id,
      :binding_name,
      :schedule,
      :timezone,
      :payload,
      :idempotency_key,
      :created_by,
      :failure_policy
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_timezone(:timezone)
    |> JsonPayload.validate_map(:schedule)
    |> JsonPayload.validate_map(:payload)
    |> validate_nullable_map(:delivery)
    |> JsonPayload.validate_map(:created_by)
    |> JsonPayload.validate_map(:failure_policy)
    |> foreign_key_constraint(:agent_uid)
    |> unique_constraint([:agent_uid, :session_id, :idempotency_key],
      name: :actor_cron_schedules_idempotency_index
    )
    |> unique_constraint([:agent_uid, :name],
      name: :actor_cron_schedules_agent_name_index
    )
    |> check_constraint(:status, name: :actor_cron_schedules_status_check)
    |> check_constraint(:timezone, name: :actor_cron_schedules_timezone_present)
    |> check_constraint(:idempotency_key,
      name: :actor_cron_schedules_idempotency_key_present
    )
    |> check_constraint(:schedule, name: :actor_cron_schedules_schedule_object)
    |> check_constraint(:payload, name: :actor_cron_schedules_payload_object)
    |> check_constraint(:delivery, name: :actor_cron_schedules_delivery_object)
    |> check_constraint(:created_by, name: :actor_cron_schedules_created_by_object)
    |> check_constraint(:failure_policy, name: :actor_cron_schedules_failure_policy_object)
  end

  defp validate_nullable_map(changeset, field) do
    case get_change(changeset, field, get_field(changeset, field)) do
      nil -> changeset
      _value -> JsonPayload.validate_map(changeset, field)
    end
  end

  defp validate_timezone(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case DateTime.now(value) do
        {:ok, _now} -> []
        {:error, reason} -> [{field, "is not a valid timezone: #{inspect(reason)}"}]
      end
    end)
  end

  defp normalize_blank(changeset, fields) when is_list(fields) do
    Enum.reduce(fields, changeset, &normalize_blank(&2, &1))
  end

  defp normalize_blank(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      value ->
        value
    end)
  end

  defp normalize_uid(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> String.downcase(value)
      value -> value
    end)
  end
end
