defmodule Ankole.SubagentDelegations.Schemas.Delegation do
  @moduledoc """
  Durable subagent delegation work item.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Principals.Principal
  alias Ankole.Ecto.JSONPayload

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @runtimes ~w(task_worker deep_research)
  @modes ~w(general forecast retrospect)
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

  @doc "Returns the supported delegation runtime categories."
  @spec runtimes() :: [String.t()]
  def runtimes, do: @runtimes

  @doc "Returns the supported Deep Research modes."
  @spec modes() :: [String.t()]
  def modes, do: @modes

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

  schema "subagent_delegations" do
    belongs_to(:agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey
    )

    field(:session_id, :string)
    field(:actor_event_id, Ecto.UUID)
    field(:tool_call_id, :string)
    field(:runtime_thread_id, :string)
    field(:runtime, :string, default: "task_worker")
    field(:mode, :string)
    belongs_to(:source_delegation, __MODULE__, type: Ecto.UUID)
    field(:actual_outcome, :boolean)
    field(:codex_account_id, :string, default: "aigateway")
    field(:title, :string)
    field(:task, :string)
    field(:background, :string)
    field(:notes, :string)
    field(:reply_route, :map, default: %{})
    field(:attempts, :integer, default: 0)
    field(:workdir, :string)
    field(:status, :string)
    field(:queued_at, :utc_datetime_usec)
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
    field(:workspace_retention_days, :integer)
    field(:workspace_cleaned_at, :utc_datetime_usec)
    field(:result, :map, default: %{})
    field(:error, :map, default: %{})
    field(:metadata, :map, default: %{})

    has_many(:turns, Ankole.SubagentDelegations.Schemas.Turn)

    timestamps()
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(delegation, attrs) do
    delegation
    |> cast(attrs, [
      :agent_uid,
      :session_id,
      :actor_event_id,
      :tool_call_id,
      :runtime_thread_id,
      :runtime,
      :mode,
      :source_delegation_id,
      :actual_outcome,
      :codex_account_id,
      :title,
      :task,
      :background,
      :notes,
      :reply_route,
      :attempts,
      :workdir,
      :status,
      :queued_at,
      :started_at,
      :completed_at,
      :workspace_retention_days,
      :result,
      :error,
      :metadata
    ])
    |> normalize_blank([
      :agent_uid,
      :session_id,
      :tool_call_id,
      :runtime_thread_id,
      :runtime,
      :mode,
      :codex_account_id,
      :title,
      :background,
      :notes,
      :workdir,
      :status
    ])
    |> validate_required([
      :agent_uid,
      :session_id,
      :runtime,
      :codex_account_id,
      :reply_route,
      :attempts,
      :status,
      :result,
      :error,
      :metadata
    ])
    |> validate_inclusion(:runtime, @runtimes)
    |> validate_inclusion(:mode, @modes, allow_nil: true)
    |> validate_research_contract()
    |> validate_inclusion(:status, @statuses)
    |> validate_change(:task, fn :task, task ->
      if is_binary(task) and String.trim(task) != "", do: [], else: [task: "can't be blank"]
    end)
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
    |> validate_number(:workspace_retention_days,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 3_650
    )
    |> JSONPayload.validate_map(:reply_route)
    |> JSONPayload.validate_map(:result, allow_datetime: true)
    |> JSONPayload.validate_map(:error, allow_datetime: true)
    |> JSONPayload.validate_map(:metadata, allow_datetime: true)
    |> foreign_key_constraint(:agent_uid)
    |> foreign_key_constraint(:actor_event_id)
    |> foreign_key_constraint(:source_delegation_id)
    |> unique_constraint([:agent_uid, :session_id, :tool_call_id],
      name: :subagent_delegations_parent_tool_call_index
    )
    |> check_constraint(:runtime, name: :subagent_delegations_runtime_check)
    |> check_constraint(:mode, name: :subagent_delegations_research_contract_check)
    |> check_constraint(:reply_route, name: :subagent_delegations_reply_route_object)
    |> check_constraint(:attempts, name: :subagent_delegations_attempts_nonnegative)
    |> check_constraint(:status, name: :subagent_delegations_status_check)
    |> check_constraint(:workspace_retention_days,
      name: :subagent_delegations_workspace_retention_check
    )
    |> check_constraint(:result, name: :subagent_delegations_result_object)
    |> check_constraint(:error, name: :subagent_delegations_error_object)
    |> check_constraint(:metadata, name: :subagent_delegations_metadata_object)
  end

  @spec creation_changeset(struct(), map()) :: Ecto.Changeset.t()
  def creation_changeset(delegation, attrs) do
    delegation
    |> changeset(attrs)
    |> validate_required([:tool_call_id, :title, :task, :workdir])
    |> validate_change(:workdir, fn :workdir, path ->
      expanded = Path.expand(path)

      if expanded == "/workspace" or String.starts_with?(expanded, "/workspace/") do
        []
      else
        [workdir: "must stay under /workspace"]
      end
    end)
  end

  defp validate_research_contract(changeset) do
    runtime = get_field(changeset, :runtime)
    mode = get_field(changeset, :mode)
    source_delegation_id = get_field(changeset, :source_delegation_id)
    actual_outcome = get_field(changeset, :actual_outcome)

    cond do
      runtime == "task_worker" and
        is_nil(mode) and is_nil(source_delegation_id) and is_nil(actual_outcome) ->
        changeset

      runtime == "task_worker" ->
        add_error(changeset, :runtime, "task_worker does not accept research fields")

      runtime == "deep_research" and mode == "retrospect" and
          not is_nil(source_delegation_id) ->
        changeset

      runtime == "deep_research" and mode in ["general", "forecast"] and
        is_nil(source_delegation_id) and is_nil(actual_outcome) ->
        changeset

      runtime == "deep_research" and is_nil(mode) ->
        add_error(changeset, :mode, "is required for deep_research")

      runtime == "deep_research" and mode == "retrospect" ->
        add_error(changeset, :source_delegation_id, "is required for retrospect")

      runtime == "deep_research" ->
        add_error(changeset, :mode, "does not accept these research fields")

      true ->
        changeset
    end
  end
end
