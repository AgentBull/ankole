defmodule Ankole.AutomationJobs.Schemas.Run do
  @moduledoc """
  Durable execution ledger for one automation job trigger.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.AutomationJobs.Schemas.Job
  alias Ankole.Ecto.JSONPayload

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :id
  @timestamps_opts [type: :utc_datetime_usec]
  @statuses ~w(queued running succeeded failed cancelled)

  @type t :: %__MODULE__{}

  schema "automation_job_runs" do
    belongs_to :automation_job, Job

    field :event, :map
    field :status, :string, default: "queued"
    field :attempts, :integer, default: 0
    field :attempt_id, Ecto.UUID
    field :oban_job_id, :integer
    field :started_at, :utc_datetime_usec
    field :last_attempt_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :exit_code, :integer
    field :error, :string
    field :stdout, :string, default: ""
    field :stderr, :string, default: ""
    field :stdout_truncated, :boolean, default: false
    field :stderr_truncated, :boolean, default: false

    timestamps()
  end

  @doc """
  Builds a changeset for an automation job run.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :automation_job_id,
      :event,
      :status,
      :attempts,
      :attempt_id,
      :oban_job_id,
      :started_at,
      :last_attempt_at,
      :finished_at,
      :exit_code,
      :error,
      :stdout,
      :stderr,
      :stdout_truncated,
      :stderr_truncated
    ])
    |> validate_required([
      :automation_job_id,
      :event,
      :status,
      :attempts,
      :stdout_truncated,
      :stderr_truncated
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
    |> validate_length(:error, max: 65_536)
    |> validate_length(:stdout, max: 65_536)
    |> validate_length(:stderr, max: 65_536)
    |> JSONPayload.validate_map(:event)
    |> foreign_key_constraint(:automation_job_id)
    |> check_constraint(:id, name: :automation_job_runs_id_range)
    |> check_constraint(:status, name: :automation_job_runs_status_check)
    |> check_constraint(:attempts, name: :automation_job_runs_attempts_nonnegative)
    |> check_constraint(:event, name: :automation_job_runs_event_object)
    |> check_constraint(:stdout, name: :automation_job_runs_logs_bounded)
    |> check_constraint(:status, name: :automation_job_runs_lifecycle_check)
  end
end
