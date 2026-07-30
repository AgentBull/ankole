defmodule Ankole.AutomationJobs.Schemas.Job do
  @moduledoc """
  Durable definition of one Agent-owned automation script.
  """

  use Ecto.Schema

  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]
  import Ecto.Changeset

  alias Ankole.AutomationJobs.Schemas.Run
  alias Ankole.Ecto.JSONPayload
  alias Ankole.Principals.Principal
  alias Ankole.SignalsGateway.ActorEvent

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @statuses ~w(active cancelled expired)

  @type t :: %__MODULE__{}

  schema "automation_jobs" do
    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey

    field :owner_session_id, :string

    belongs_to :source_actor_event, ActorEvent,
      foreign_key: :source_actor_event_id,
      type: Ecto.UUID

    field :source_entry_id, :string
    field :source_provenance, :map, default: %{}
    field :reply_route, :map, default: %{}
    field :directory_path, :string
    field :label, :string
    field :wake_on_failure, :boolean, default: false
    field :status, :string, default: "active"
    field :expires_at, :utc_datetime_usec
    field :cancelled_at, :utc_datetime_usec

    has_many :runs, Run, foreign_key: :automation_job_id

    timestamps()
  end

  @doc """
  Builds a changeset for an automation job.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(job, attrs) do
    job
    |> cast(attrs, [
      :agent_uid,
      :owner_session_id,
      :source_actor_event_id,
      :source_entry_id,
      :source_provenance,
      :reply_route,
      :directory_path,
      :label,
      :wake_on_failure,
      :status,
      :expires_at,
      :cancelled_at
    ])
    |> normalize_blank([
      :agent_uid,
      :owner_session_id,
      :source_entry_id,
      :directory_path,
      :label,
      :status
    ])
    |> validate_required([
      :agent_uid,
      :owner_session_id,
      :source_provenance,
      :reply_route,
      :directory_path,
      :label,
      :wake_on_failure,
      :status
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:directory_path, max: 4096)
    |> validate_length(:label, max: 500)
    |> validate_absolute_directory()
    |> JSONPayload.validate_map(:source_provenance)
    |> JSONPayload.validate_map(:reply_route)
    |> foreign_key_constraint(:agent_uid)
    |> foreign_key_constraint(:source_actor_event_id)
    |> check_constraint(:id, name: :automation_jobs_id_range)
    |> check_constraint(:status, name: :automation_jobs_status_check)
    |> check_constraint(:owner_session_id, name: :automation_jobs_owner_session_present)
    |> check_constraint(:directory_path, name: :automation_jobs_directory_path_present)
    |> check_constraint(:label, name: :automation_jobs_label_present)
    |> check_constraint(:source_provenance,
      name: :automation_jobs_source_provenance_object
    )
    |> check_constraint(:reply_route, name: :automation_jobs_reply_route_object)
    |> check_constraint(:status, name: :automation_jobs_terminal_time_check)
  end

  defp validate_absolute_directory(changeset) do
    validate_change(changeset, :directory_path, fn :directory_path, path ->
      if Path.type(path) == :absolute,
        do: [],
        else: [directory_path: "must be an absolute path"]
    end)
  end
end
