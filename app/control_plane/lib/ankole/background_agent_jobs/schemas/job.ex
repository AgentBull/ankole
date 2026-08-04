defmodule Ankole.BackgroundAgentJobs.Schemas.Job do
  @moduledoc """
  Durable BackgroundAgentJob work item.

  Jobs retain one optional workspace template and one runtime projection. The
  first executable admission records the projection, and later attempts use it
  to keep the same logical execution choices.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.AIAgent.Library.AgentPlugins.Contract
  alias Ankole.Ecto.JSONPayload
  alias Ankole.Principals.Principal

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @statuses ~w(queued running waiting_on_user succeeded failed stopped)
  @terminal_statuses ~w(succeeded failed stopped)
  @running_statuses ~w(running)
  @model_profile ~r/\A[a-z][a-z0-9_-]{0,63}\z/
  @status_transitions %{
    "queued" => ~w(queued running failed stopped),
    "running" => ~w(running waiting_on_user succeeded failed stopped),
    "waiting_on_user" => ~w(waiting_on_user running succeeded failed stopped),
    "succeeded" => ~w(succeeded),
    "failed" => ~w(failed),
    "stopped" => ~w(stopped)
  }

  @doc "Returns the complete durable status vocabulary."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Returns statuses with no live execution."
  @spec terminal_statuses() :: [String.t()]
  def terminal_statuses, do: @terminal_statuses

  @doc "Returns statuses that occupy an agent running slot."
  @spec running_statuses() :: [String.t()]
  def running_statuses, do: @running_statuses

  @doc "Checks the canonical lifecycle transition table."
  @spec transition_allowed?(String.t(), String.t()) :: boolean()
  def transition_allowed?(current, next) when is_binary(current) and is_binary(next) do
    next in Map.get(@status_transitions, current, [])
  end

  schema "background_agent_jobs" do
    belongs_to(:agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey
    )

    field(:owner_session_id, :string)
    field(:source_actor_event_id, Ecto.UUID)
    field(:source_tool_call_id, :string)
    field(:continued_from_job_id, :integer)
    field(:workspace_owner_job_id, :integer)
    field(:runtime_thread_id, :string)
    field(:title, :string)
    field(:task, :string)
    field(:reply_route, :map, default: %{})
    field(:attempts, :integer, default: 0)

    field(:workspace_template_id, :string)
    field(:model_profile, :string, default: "coding")
    field(:runtime_projection, :map)

    field(:status, :string)
    field(:queued_at, :utc_datetime_usec)
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
    field(:result, :map, default: %{})
    field(:error, :map, default: %{})
    field(:metadata, :map, default: %{})

    has_many(:turns, Ankole.BackgroundAgentJobs.Schemas.Turn)

    timestamps()
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(job, attrs) do
    job
    |> cast(attrs, [
      :agent_uid,
      :owner_session_id,
      :source_actor_event_id,
      :source_tool_call_id,
      :continued_from_job_id,
      :workspace_owner_job_id,
      :runtime_thread_id,
      :title,
      :task,
      :reply_route,
      :attempts,
      :workspace_template_id,
      :model_profile,
      :runtime_projection,
      :status,
      :queued_at,
      :started_at,
      :completed_at,
      :result,
      :error,
      :metadata
    ])
    |> normalize_blank([
      :agent_uid,
      :owner_session_id,
      :source_tool_call_id,
      :continued_from_job_id,
      :workspace_owner_job_id,
      :runtime_thread_id,
      :title,
      :workspace_template_id,
      :model_profile,
      :status
    ])
    |> validate_required([
      :agent_uid,
      :owner_session_id,
      :workspace_owner_job_id,
      :reply_route,
      :attempts,
      :model_profile,
      :status,
      :result,
      :error,
      :metadata
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_change(:task, fn :task, task ->
      if is_binary(task) and String.trim(task) != "", do: [], else: [task: "can't be blank"]
    end)
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
    |> validate_format(:model_profile, @model_profile)
    |> validate_workspace_template_id()
    |> JSONPayload.validate_map(:reply_route)
    |> validate_optional_map(:runtime_projection)
    |> JSONPayload.validate_map(:result, allow_datetime: true)
    |> JSONPayload.validate_map(:error, allow_datetime: true)
    |> JSONPayload.validate_map(:metadata, allow_datetime: true)
    |> foreign_key_constraint(:agent_uid)
    |> foreign_key_constraint(:source_actor_event_id)
    |> foreign_key_constraint(:continued_from_job_id)
    |> foreign_key_constraint(:workspace_owner_job_id)
    |> unique_constraint([:agent_uid, :owner_session_id, :source_tool_call_id],
      name: :background_agent_jobs_source_tool_call_index
    )
    |> unique_constraint(:continued_from_job_id,
      name: :background_agent_jobs_continued_from_job_index
    )
    |> check_constraint(:id, name: :background_agent_jobs_id_range)
    |> check_constraint(:continued_from_job_id,
      name: :background_agent_jobs_continued_from_not_self
    )
    |> check_constraint(:reply_route, name: :background_agent_jobs_reply_route_object)
    |> check_constraint(:attempts, name: :background_agent_jobs_attempts_nonnegative)
    |> check_constraint(:workspace_template_id,
      name: :background_agent_jobs_workspace_template_id_valid
    )
    |> check_constraint(:model_profile, name: :background_agent_jobs_model_profile_valid)
    |> check_constraint(:runtime_projection,
      name: :background_agent_jobs_runtime_projection_object
    )
    |> check_constraint(:status, name: :background_agent_jobs_status_check)
    |> check_constraint(:result, name: :background_agent_jobs_result_object)
    |> check_constraint(:error, name: :background_agent_jobs_error_object)
    |> check_constraint(:metadata, name: :background_agent_jobs_metadata_object)
  end

  defp validate_workspace_template_id(changeset) do
    validate_change(changeset, :workspace_template_id, fn :workspace_template_id, id ->
      if Contract.validate_identifier(id) == :ok,
        do: [],
        else: [workspace_template_id: "must be an Agent Plugin identifier"]
    end)
  end

  defp validate_optional_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value), do: [], else: [{field, "must be an object"}]
    end)
  end

  @spec creation_changeset(struct(), map()) :: Ecto.Changeset.t()
  def creation_changeset(job, attrs) do
    job
    |> changeset(attrs)
    |> validate_required([:source_tool_call_id, :workspace_owner_job_id, :title, :task])
  end
end
