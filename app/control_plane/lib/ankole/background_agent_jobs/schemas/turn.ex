defmodule Ankole.BackgroundAgentJobs.Schemas.Turn do
  @moduledoc """
  One durable, normalized execution trajectory for one runtime turn.

  Streaming protocol frames are assembled by Agent Computer before they cross
  the control-plane boundary. The Turn row stores the trajectory header, and
  trajectory group rows store the semantic ChatML messages.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Ecto.JSONPayload
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.BackgroundAgentJobs.Trajectory

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @kinds ~w(agent compaction)
  @statuses ~w(in_progress completed failed interrupted)
  @terminal_statuses ~w(completed failed interrupted)
  @plan_statuses ~w(pending in_progress completed)
  @max_tools_used 128
  @max_skills_used 128
  @max_files_changed 1_024
  @max_plan_steps 100
  @status_transitions %{
    "in_progress" => @statuses,
    "completed" => ["completed"],
    "failed" => ["failed"],
    "interrupted" => ["interrupted"]
  }

  @doc "Returns the durable turn kinds."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "Returns the durable turn statuses."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Returns statuses that cannot transition to another state."
  @spec terminal_statuses() :: [String.t()]
  def terminal_statuses, do: @terminal_statuses

  @doc "Checks the canonical turn transition table."
  @spec transition_allowed?(String.t(), String.t()) :: boolean()
  def transition_allowed?(current, next) when is_binary(current) and is_binary(next) do
    next in Map.get(@status_transitions, current, [])
  end

  schema "background_agent_job_turns" do
    belongs_to(:job, Job, type: :id)

    field(:attempt, :integer)
    field(:runtime_thread_id, :string)
    field(:runtime_turn_id, :string)
    field(:kind, :string, default: "agent")
    field(:status, :string)
    field(:revision, :integer)
    field(:trajectory, :map)

    field(:progress, :map,
      default: %{
        "completed_items" => 0,
        "tool_calls" => 0,
        "tools_used" => [],
        "files_changed" => []
      }
    )

    field(:usage, :map)
    field(:error, :map, default: %{})
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)

    timestamps()
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(turn, attrs) do
    turn
    |> cast(attrs, [
      :job_id,
      :attempt,
      :runtime_thread_id,
      :runtime_turn_id,
      :kind,
      :status,
      :revision,
      :trajectory,
      :progress,
      :usage,
      :error,
      :started_at,
      :completed_at
    ])
    |> normalize_blank([:runtime_thread_id, :runtime_turn_id, :kind, :status])
    |> validate_required([
      :job_id,
      :attempt,
      :runtime_thread_id,
      :runtime_turn_id,
      :kind,
      :status,
      :revision,
      :trajectory,
      :progress,
      :error,
      :started_at
    ])
    |> validate_number(:attempt, greater_than: 0)
    |> validate_number(:revision, greater_than_or_equal_to: 0)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> JSONPayload.validate_map(:trajectory, allow_datetime: true)
    |> JSONPayload.validate_map(:progress, allow_datetime: true)
    |> validate_optional_json_map(:usage)
    |> JSONPayload.validate_map(:error, allow_datetime: true)
    |> validate_trajectory()
    |> validate_progress()
    |> validate_usage()
    |> validate_completion()
    |> foreign_key_constraint(:job_id)
    |> unique_constraint([:job_id, :runtime_turn_id],
      name: :background_agent_job_turns_runtime_turn_index
    )
    |> check_constraint(:attempt, name: :background_agent_job_turns_attempt_positive)
    |> check_constraint(:revision, name: :background_agent_job_turns_revision_nonnegative)
    |> check_constraint(:kind, name: :background_agent_job_turns_kind_check)
    |> check_constraint(:status, name: :background_agent_job_turns_status_check)
    |> check_constraint(:trajectory, name: :background_agent_job_turns_trajectory_check)
    |> check_constraint(:progress, name: :background_agent_job_turns_progress_object)
    |> check_constraint(:usage, name: :background_agent_job_turns_usage_object)
    |> check_constraint(:error, name: :background_agent_job_turns_error_object)
    |> check_constraint(:completed_at, name: :background_agent_job_turns_completion_check)
  end

  defp validate_trajectory(changeset) do
    validate_change(changeset, :trajectory, fn :trajectory, trajectory ->
      cond do
        trajectory["format"] != "ankole_chatml" or trajectory["version"] != 1 ->
          [trajectory: "must be an ankole_chatml v1 header"]

        Trajectory.valid_header?(trajectory) ->
          []

        true ->
          [trajectory: "must contain only canonical header metadata"]
      end
    end)
  end

  defp validate_optional_json_map(changeset, field) do
    case fetch_change(changeset, field) do
      {:ok, nil} -> changeset
      _value -> JSONPayload.validate_map(changeset, field, allow_datetime: true)
    end
  end

  defp validate_progress(changeset) do
    validate_change(changeset, :progress, fn :progress, progress ->
      if valid_progress?(progress),
        do: [],
        else: [progress: "must be a valid runtime progress snapshot"]
    end)
  end

  defp valid_progress?(
         %{
           "completed_items" => completed_items,
           "tool_calls" => tool_calls,
           "tools_used" => tools_used,
           "files_changed" => files_changed
         } = progress
       ) do
    allowed = ~w(completed_items tool_calls tools_used files_changed skills_used plan active_item)

    Map.keys(progress) -- allowed == [] and
      nonnegative_integer?(completed_items) and
      nonnegative_integer?(tool_calls) and
      valid_tools_used?(tools_used, tool_calls) and
      string_list?(files_changed, @max_files_changed) and
      files_changed == Enum.sort(files_changed) and files_changed == Enum.uniq(files_changed) and
      valid_optional_skills_used?(Map.get(progress, "skills_used")) and
      valid_optional_plan?(Map.get(progress, "plan")) and
      valid_optional_active_item?(Map.get(progress, "active_item"))
  end

  defp valid_progress?(_progress), do: false

  defp valid_tools_used?(tools_used, tool_calls) when is_list(tools_used) do
    if length(tools_used) <= @max_tools_used and Enum.all?(tools_used, &valid_tool_usage?/1) do
      tool_names = Enum.map(tools_used, & &1["name"])

      tool_names == Enum.sort(tool_names) and tool_names == Enum.uniq(tool_names) and
        Enum.sum(Enum.map(tools_used, & &1["calls"])) == tool_calls
    else
      false
    end
  end

  defp valid_tools_used?(_tools_used, _tool_calls), do: false

  defp valid_optional_skills_used?(nil), do: true

  defp valid_optional_skills_used?(skills) do
    string_list?(skills, @max_skills_used) and skills == Enum.sort(skills) and
      skills == Enum.uniq(skills)
  end

  defp valid_tool_usage?(%{"name" => name, "calls" => calls} = usage) do
    Map.keys(usage) -- ~w(name calls) == [] and nonempty_string?(name) and
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
    Map.keys(item) -- ~w(id name) == [] and nonempty_string?(id) and nonempty_string?(name)
  end

  defp valid_optional_active_item?(_item), do: false

  defp validate_usage(changeset) do
    validate_change(changeset, :usage, fn :usage, usage ->
      if is_nil(usage) or valid_usage?(usage),
        do: [],
        else: [usage: "must be a valid official thread usage snapshot"]
    end)
  end

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

  defp validate_completion(changeset) do
    status = get_field(changeset, :status)
    completed_at = get_field(changeset, :completed_at)

    cond do
      status in @terminal_statuses and is_nil(completed_at) ->
        add_error(changeset, :completed_at, "is required for a terminal turn")

      status not in @terminal_statuses and not is_nil(completed_at) ->
        add_error(changeset, :completed_at, "must be empty for an active turn")

      true ->
        changeset
    end
  end
end
