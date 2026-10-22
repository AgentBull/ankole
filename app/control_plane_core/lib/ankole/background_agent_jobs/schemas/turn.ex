defmodule Ankole.BackgroundAgentJobs.Schemas.Turn do
  @moduledoc """
  One durable, normalized execution trajectory for one runtime turn.

  Agent Computer assembles streaming protocol frames before they cross the
  control-plane boundary. The Turn row stores the trajectory header. TurnItem
  rows store sanitized thread items that are projected to ChatML on read.
  """

  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.BackgroundAgentJobs,
    extensions: [AshStateMachine]

  alias Ankole.BackgroundAgentJobs.Trajectory

  @kinds ~w(agent compaction)
  @terminal_statuses [:completed, :failed, :interrupted]
  @statuses [:in_progress | @terminal_statuses]
  @plan_statuses ~w(pending in_progress completed)
  @max_tools_used 128
  @max_tool_execution_mechanisms 256
  @tool_execution_mechanisms ~w(local_dynamic provider_hosted)
  @max_skills_used 128
  @max_files_changed 1_024
  @max_plan_steps 100

  @type t :: %__MODULE__{}
  @type status :: :in_progress | :completed | :failed | :interrupted

  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "Whether the turn ran on the given lead thread."
  @spec lead?(t(), String.t() | nil) :: boolean()
  def lead?(%__MODULE__{} = turn, lead_thread_id),
    do: is_binary(lead_thread_id) and turn.runtime_thread_id == lead_thread_id

  @doc "The lead thread of one attempt is the thread of its first turn."
  @spec attempt_lead_thread_id([t()]) :: String.t() | nil
  def attempt_lead_thread_id(turns) do
    case turns do
      [first | _rest] -> first.runtime_thread_id
      [] -> nil
    end
  end

  @doc "Chronological sort key: start time, then id."
  @spec start_key(t()) :: {integer(), Ecto.UUID.t()}
  def start_key(%__MODULE__{} = turn), do: {datetime_key(turn.started_at), turn.id}

  @doc "Recency sort key: last update, then id."
  @spec update_key(t()) :: {integer(), Ecto.UUID.t()}
  def update_key(%__MODULE__{} = turn),
    do: {datetime_key(turn.updated_at || turn.started_at), turn.id}

  defp datetime_key(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp datetime_key(_datetime), do: 0

  postgres do
    table("background_agent_job_turns")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:job_id, "background_agent_job_turns_job_id_fkey"}])
    identity_index_names(runtime_turn: "background_agent_job_turns_runtime_turn_index")

    check_constraints do
      check_constraint(:attempt, "background_agent_job_turns_attempt_positive")
      check_constraint(:revision, "background_agent_job_turns_revision_nonnegative")
      check_constraint(:kind, "background_agent_job_turns_kind_check")
      check_constraint(:status, "background_agent_job_turns_status_check")
      check_constraint(:trajectory, "background_agent_job_turns_trajectory_check")
      check_constraint(:progress, "background_agent_job_turns_progress_object")
      check_constraint(:usage, "background_agent_job_turns_usage_object")
      check_constraint(:error, "background_agent_job_turns_error_object")
      check_constraint(:completed_at, "background_agent_job_turns_completion_check")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      public?: true,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:job_id, :integer, allow_nil?: false, public?: true)
    attribute(:attempt, :integer, allow_nil?: false, constraints: [min: 1], public?: true)
    attribute(:runtime_thread_id, :string, allow_nil?: false, public?: true)
    attribute(:runtime_turn_id, :string, allow_nil?: false, public?: true)
    attribute(:kind, :string, default: "agent", allow_nil?: false, public?: true)

    attribute(:status, Ankole.Ash.Types.State,
      constraints: [one_of: @statuses],
      allow_nil?: false,
      public?: true
    )

    attribute(:revision, :integer, allow_nil?: false, constraints: [min: 0], public?: true)

    attribute(:trajectory, Ankole.Ash.Types.JSONMap,
      allow_nil?: false,
      public?: true,
      constraints: [allow_datetime?: true]
    )

    attribute(:progress, Ankole.Ash.Types.JSONMap,
      constraints: [allow_datetime?: true],
      allow_nil?: false,
      public?: true,
      default: %{
        "completed_items" => 0,
        "tool_calls" => 0,
        "tools_used" => [],
        "files_changed" => []
      }
    )

    attribute(:usage, Ankole.Ash.Types.JSONMap,
      public?: true,
      constraints: [allow_datetime?: true]
    )

    attribute(:error, Ankole.Ash.Types.JSONMap,
      default: %{},
      allow_nil?: false,
      public?: true,
      constraints: [allow_datetime?: true]
    )

    attribute(:started_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:completed_at, :utc_datetime_usec, public?: true)
    timestamps(type: :utc_datetime_usec)
  end

  identities do
    identity(:runtime_turn, [:job_id, :runtime_turn_id], all_tenants?: true)
  end

  relationships do
    belongs_to :job, Ankole.BackgroundAgentJobs.Schemas.Job do
      source_attribute(:job_id)
      attribute_type(:integer)
      define_attribute?(false)
      allow_nil?(false)
      public?(true)
    end

    has_many :items, Ankole.BackgroundAgentJobs.Schemas.TurnItem do
      destination_attribute(:turn_id)
      public?(true)
    end
  end

  state_machine do
    state_attribute(:status)
    initial_states(@statuses)

    transitions do
      transition(:checkpoint,
        from: :in_progress,
        to: @statuses
      )

      transition(:checkpoint, from: :completed, to: :completed)
      transition(:checkpoint, from: :failed, to: :failed)
      transition(:checkpoint, from: :interrupted, to: :interrupted)
      transition(:interrupt, from: :in_progress, to: :interrupted)
    end
  end

  @checkpoint_attributes [
    :job_id,
    :attempt,
    :runtime_thread_id,
    :runtime_turn_id,
    :kind,
    :revision,
    :trajectory,
    :progress,
    :usage,
    :error,
    :started_at,
    :completed_at
  ]

  validations do
    validate(attribute_in(:kind, @kinds))

    validate(present(:completed_at),
      where: [attribute_in(:status, @terminal_statuses)]
    )

    validate(absent(:completed_at), where: [attribute_equals(:status, :in_progress)])
  end

  actions do
    defaults([:read])

    create :record do
      accept([:status | @checkpoint_attributes])

      validate(fn changeset, _context -> validate_checkpoint(changeset) end,
        only_when_valid?: true
      )
    end

    update :checkpoint do
      accept(@checkpoint_attributes -- [:job_id, :attempt, :runtime_thread_id, :runtime_turn_id])

      argument(:next_status, Ankole.Ash.Types.State,
        constraints: [one_of: @statuses],
        allow_nil?: false
      )

      change(
        {Ankole.BackgroundAgentJobs.Changes.TransitionToArgument,
         missing: :background_agent_job_turn_status_missing}
      )

      validate(fn changeset, _context -> validate_checkpoint(changeset) end,
        only_when_valid?: true
      )

      validate(fn changeset, _context ->
        if Ash.Changeset.get_attribute(changeset, :revision) > changeset.data.revision,
          do: :ok,
          else: {:error, field: :revision, message: "must advance the recorded checkpoint"}
      end)

      change(fn changeset, _context ->
        Ash.Changeset.filter(changeset,
          status: changeset.data.status,
          revision: changeset.data.revision
        )
      end)
    end

    update :interrupt do
      require_atomic?(true)
      accept([])
      argument(:now, :utc_datetime_usec, allow_nil?: false)

      argument(:error, Ankole.Ash.Types.JSONMap,
        allow_nil?: false,
        constraints: [allow_datetime?: true]
      )

      change(filter(expr(status == :in_progress)))
      change(transition_state(:interrupted))
      change(set_attribute(:completed_at, arg(:now)))
      change(set_attribute(:updated_at, arg(:now)))
      change(set_attribute(:error, arg(:error)))
      change(atomic_update(:revision, expr(revision + 1)))
      change(atomic_update(:progress, expr(fragment("? - 'active_item'", progress))))
    end

    update :mark_content_truncated do
      accept([])

      change(
        atomic_update(
          :trajectory,
          expr(
            fragment(
              "jsonb_set(?, '{metadata}', COALESCE(?->'metadata', '{}'::jsonb) || '{\"content_truncated\":true}'::jsonb)",
              trajectory,
              trajectory
            )
          )
        )
      )
    end

    # Records one Worker checkpoint and its items, with the Worker turn fence,
    # the Agent slot lock, and the Job lock, in one transaction.
    action :record_from_worker, :struct do
      constraints(instance_of: __MODULE__)
      argument(:job_id, :integer, allow_nil?: false)
      argument(:agent_uid, :string, allow_nil?: false)
      argument(:attrs, :map, allow_nil?: false)

      argument(:turn_ref, :struct,
        allow_nil?: false,
        constraints: [instance_of: Ankole.Sessions.JobTurnRef]
      )

      argument(:worker_id, :string, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Errors.wrap(
          Ankole.BackgroundAgentJobs.Lifecycle.upsert_turn_from_worker_in_tx(
            Ankole.Repo,
            input.arguments.job_id,
            input.arguments.agent_uid,
            input.arguments.attrs,
            input.arguments.turn_ref,
            input.arguments.worker_id
          )
        )
      end)
    end
  end

  defp validate_checkpoint(changeset) do
    trajectory = Ash.Changeset.get_attribute(changeset, :trajectory)
    progress = Ash.Changeset.get_attribute(changeset, :progress)
    usage = Ash.Changeset.get_attribute(changeset, :usage)

    cond do
      trajectory["format"] != "ankole_chatml" or trajectory["version"] != 1 ->
        {:error, field: :trajectory, message: "must be an ankole_chatml v1 header"}

      not Trajectory.valid_header?(trajectory) ->
        {:error, field: :trajectory, message: "must contain only canonical header metadata"}

      not valid_progress?(progress) ->
        {:error, field: :progress, message: "must be a valid runtime progress snapshot"}

      not is_nil(usage) and not valid_usage?(usage) ->
        {:error, field: :usage, message: "must be a valid official thread usage snapshot"}

      true ->
        :ok
    end
  end

  defp valid_progress?(
         %{
           "completed_items" => completed_items,
           "tool_calls" => tool_calls,
           "tools_used" => tools_used,
           "files_changed" => files_changed
         } = progress
       ) do
    allowed =
      ~w(completed_items tool_calls tools_used tool_execution_mechanisms files_changed skills_used plan active_item)

    Map.keys(progress) -- allowed == [] and
      nonnegative_integer?(completed_items) and
      nonnegative_integer?(tool_calls) and
      valid_tools_used?(tools_used, tool_calls) and
      valid_optional_tool_execution_mechanisms?(
        Map.get(progress, "tool_execution_mechanisms"),
        tools_used
      ) and
      string_list?(files_changed, @max_files_changed) and
      files_changed == Enum.sort(files_changed) and files_changed == Enum.uniq(files_changed) and
      valid_optional_skills_used?(Map.get(progress, "skills_used")) and
      valid_optional_plan?(Map.get(progress, "plan")) and
      valid_optional_active_item?(Map.get(progress, "active_item"))
  end

  defp valid_progress?(_progress), do: false

  defp valid_tools_used?(tools_used, tool_calls) when is_list(tools_used) do
    if length(tools_used) <= @max_tools_used and Enum.all?(tools_used, &valid_tool_usage?/1) do
      tool_identities = Enum.map(tools_used, &tool_identity/1)

      tool_identities == Enum.sort(tool_identities) and
        tool_identities == Enum.uniq(tool_identities) and
        Enum.sum(Enum.map(tools_used, & &1["calls"])) == tool_calls
    else
      false
    end
  end

  defp valid_tools_used?(_tools_used, _tool_calls), do: false

  defp valid_optional_tool_execution_mechanisms?(nil, _tools_used), do: true

  defp valid_optional_tool_execution_mechanisms?(executions, tools_used)
       when is_list(executions) and is_list(tools_used) do
    if length(executions) <= @max_tool_execution_mechanisms and
         Enum.all?(executions, &valid_tool_execution_mechanism?/1) do
      tool_calls = Map.new(tools_used, &{tool_identity(&1), &1["calls"]})
      pairs = Enum.map(executions, &{tool_identity(&1), &1["execution_mechanism"]})

      pairs == Enum.sort(pairs) and pairs == Enum.uniq(pairs) and
        executions
        |> Enum.group_by(&tool_identity/1, & &1["calls"])
        |> Enum.all?(fn {identity, calls} ->
          Enum.sum(calls) <= Map.get(tool_calls, identity, -1)
        end)
    else
      false
    end
  end

  defp valid_optional_tool_execution_mechanisms?(_executions, _tools_used), do: false

  defp valid_tool_execution_mechanism?(execution) when is_map(execution) do
    Map.keys(execution) -- ~w(namespace name execution_mechanism calls) == [] and
      valid_optional_namespace?(execution) and
      nonempty_string?(execution["name"]) and
      execution["execution_mechanism"] in @tool_execution_mechanisms and
      is_integer(execution["calls"]) and execution["calls"] > 0
  end

  defp valid_tool_execution_mechanism?(_execution), do: false

  defp valid_optional_skills_used?(nil), do: true

  defp valid_optional_skills_used?(skills) do
    string_list?(skills, @max_skills_used) and skills == Enum.sort(skills) and
      skills == Enum.uniq(skills)
  end

  defp valid_tool_usage?(%{"name" => name, "calls" => calls} = usage) do
    Map.keys(usage) -- ~w(namespace name calls) == [] and valid_optional_namespace?(usage) and
      nonempty_string?(name) and
      nonnegative_integer?(calls)
  end

  defp valid_tool_usage?(_usage), do: false

  defp valid_optional_plan?(nil), do: true

  defp valid_optional_plan?(%{"steps" => steps} = plan) do
    Map.keys(plan) -- ~w(explanation steps) == [] and
      (is_nil(Map.get(plan, "explanation")) or is_binary(plan["explanation"])) and
      is_list(steps) and length(steps) <= @max_plan_steps and
      Enum.all?(steps, &valid_plan_step?/1)
  end

  defp valid_optional_plan?(_plan), do: false

  defp valid_plan_step?(%{"step" => step, "status" => status} = value) do
    Map.keys(value) -- ~w(step status) == [] and nonempty_string?(step) and
      status in @plan_statuses
  end

  defp valid_plan_step?(_value), do: false

  defp valid_optional_active_item?(nil), do: true

  defp valid_optional_active_item?(%{"id" => id, "name" => name} = item) do
    Map.keys(item) -- ~w(id namespace name) == [] and valid_optional_namespace?(item) and
      nonempty_string?(id) and nonempty_string?(name)
  end

  defp valid_optional_active_item?(_item), do: false

  defp valid_optional_namespace?(value),
    do:
      not Map.has_key?(value, "namespace") or
        (is_binary(value["namespace"]) and value["namespace"] != "")

  defp tool_identity(value), do: {Map.get(value, "namespace") || "", value["name"]}

  defp valid_usage?(%{"thread_total" => total, "last_model_call" => last} = usage) do
    Map.keys(usage) -- ~w(thread_total last_model_call model_context_window) == [] and
      valid_usage_breakdown?(total) and valid_usage_breakdown?(last) and
      (is_nil(Map.get(usage, "model_context_window")) or
         nonnegative_integer?(usage["model_context_window"]))
  end

  defp valid_usage?(_usage), do: false

  defp valid_usage_breakdown?(%{} = breakdown) do
    keys =
      ~w(total_tokens input_tokens cached_input_tokens output_tokens reasoning_output_tokens)

    Map.keys(breakdown) -- keys == [] and keys -- Map.keys(breakdown) == [] and
      Enum.all?(keys, &nonnegative_integer?(breakdown[&1]))
  end

  defp valid_usage_breakdown?(_breakdown), do: false

  defp nonnegative_integer?(value), do: is_integer(value) and value >= 0
  defp nonempty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp string_list?(value, limit) when is_list(value) do
    length(value) <= limit and Enum.all?(value, &nonempty_string?/1)
  end

  defp string_list?(_value, _limit), do: false
end
