defmodule Ankole.BackgroundAgentJobs.Schemas.Job do
  @moduledoc """
  Durable BackgroundAgentJob work item.

  Jobs retain the capabilities selected by the caller, while each execution
  resolves those selections against the current library catalog.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.AIAgent.Library.AgentPlugins.Contract
  alias Ankole.Ecto.JSONPayload
  alias Ankole.Principals.Principal

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @statuses ~w(queued running waiting_on_user succeeded failed stopped)
  @terminal_statuses ~w(succeeded failed stopped)
  @running_statuses ~w(running)
  @status_transitions %{
    "queued" => ~w(queued running failed stopped),
    "running" => ~w(running waiting_on_user succeeded failed stopped),
    "waiting_on_user" => ~w(waiting_on_user running succeeded failed stopped),
    "succeeded" => ~w(queued succeeded),
    "failed" => ~w(queued failed),
    "stopped" => ~w(stopped)
  }

  @doc "Returns the complete durable status vocabulary."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Returns statuses with no live execution; succeeded and failed may be explicitly continued."
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
    field(:runtime_thread_id, :string)
    field(:codex_account_id, :string, default: "aigateway")
    field(:title, :string)
    field(:task, :string)
    field(:background, :string)
    field(:notes, :string)
    field(:reply_route, :map, default: %{})
    field(:attempts, :integer, default: 0)

    field(:agent_plugin_ids, {:array, :string}, default: [])
    field(:skill_names, {:array, :string}, default: [])
    field(:workspace_mounts, Ankole.Types.JSONValue, default: [])
    field(:model, :string)
    field(:reasoning_effort, :string)

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
      :runtime_thread_id,
      :codex_account_id,
      :title,
      :task,
      :background,
      :notes,
      :reply_route,
      :attempts,
      :agent_plugin_ids,
      :skill_names,
      :workspace_mounts,
      :model,
      :reasoning_effort,
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
      :runtime_thread_id,
      :codex_account_id,
      :title,
      :background,
      :notes,
      :model,
      :reasoning_effort,
      :status
    ])
    |> validate_required([
      :agent_uid,
      :owner_session_id,
      :codex_account_id,
      :reply_route,
      :attempts,
      :agent_plugin_ids,
      :skill_names,
      :workspace_mounts,
      :status,
      :result,
      :error,
      :metadata
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:reasoning_effort, Contract.reasoning_efforts(), allow_nil: true)
    |> validate_change(:task, fn :task, task ->
      if is_binary(task) and String.trim(task) != "", do: [], else: [task: "can't be blank"]
    end)
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
    |> validate_agent_plugin_ids()
    |> validate_skill_names()
    |> validate_job_contracts()
    |> JSONPayload.validate_map(:reply_route)
    |> JSONPayload.validate_map(:result, allow_datetime: true)
    |> JSONPayload.validate_map(:error, allow_datetime: true)
    |> JSONPayload.validate_map(:metadata, allow_datetime: true)
    |> foreign_key_constraint(:agent_uid)
    |> foreign_key_constraint(:source_actor_event_id)
    |> unique_constraint([:agent_uid, :owner_session_id, :source_tool_call_id],
      name: :background_agent_jobs_source_tool_call_index
    )
    |> check_constraint(:reply_route, name: :background_agent_jobs_reply_route_object)
    |> check_constraint(:attempts, name: :background_agent_jobs_attempts_nonnegative)
    |> check_constraint(:agent_plugin_ids,
      name: :background_agent_jobs_agent_plugin_ids_valid
    )
    |> check_constraint(:skill_names, name: :background_agent_jobs_skill_names_valid)
    |> check_constraint(:workspace_mounts,
      name: :background_agent_jobs_workspace_mounts_array
    )
    |> check_constraint(:model, name: :background_agent_jobs_model_present)
    |> check_constraint(:reasoning_effort,
      name: :background_agent_jobs_reasoning_effort_check
    )
    |> check_constraint(:status, name: :background_agent_jobs_status_check)
    |> check_constraint(:result, name: :background_agent_jobs_result_object)
    |> check_constraint(:error, name: :background_agent_jobs_error_object)
    |> check_constraint(:metadata, name: :background_agent_jobs_metadata_object)
  end

  defp validate_agent_plugin_ids(changeset) do
    validate_change(changeset, :agent_plugin_ids, fn :agent_plugin_ids, ids ->
      cond do
        length(ids) > 16 ->
          [agent_plugin_ids: "must contain at most 16 Agent Plugins"]

        Enum.uniq(ids) != ids ->
          [agent_plugin_ids: "must not contain duplicates"]

        Enum.any?(ids, &(Contract.validate_identifier(&1) != :ok)) ->
          [agent_plugin_ids: "must contain only Agent Plugin identifiers"]

        true ->
          []
      end
    end)
  end

  @spec creation_changeset(struct(), map()) :: Ecto.Changeset.t()
  def creation_changeset(job, attrs) do
    job
    |> changeset(attrs)
    |> validate_required([:source_tool_call_id, :title, :task])
  end

  defp validate_skill_names(changeset) do
    validate_change(changeset, :skill_names, fn :skill_names, names ->
      cond do
        length(names) > 256 ->
          [skill_names: "must contain at most 256 skills"]

        Enum.uniq(names) != names ->
          [skill_names: "must not contain duplicates"]

        Enum.any?(names, &(Contract.validate_identifier(&1) != :ok)) ->
          [skill_names: "must contain only standalone skill identifiers"]

        true ->
          []
      end
    end)
  end

  defp validate_job_contracts(changeset) do
    mounts = get_field(changeset, :workspace_mounts)

    contract_error(changeset, :workspace_mounts, Contract.validate_workspace_mounts(mounts))
  end

  defp contract_error(changeset, _field, :ok), do: changeset

  defp contract_error(changeset, field, {:error, reason}) do
    add_error(changeset, field, "is invalid", validation: reason)
  end
end
