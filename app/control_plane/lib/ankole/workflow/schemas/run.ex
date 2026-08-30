defmodule Ankole.Workflow.Schemas.Run do
  @moduledoc """
  Durable state for one Workflow program execution.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Ecto.JSONPayload
  alias Ankole.Principals.Principal

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @statuses ~w(running completed failed cancelled)
  @terminal_statuses ~w(completed failed cancelled)
  @memo_budget_bytes 6 * 1_024 * 1_024
  @model_profile ~r/\A[a-z][a-z0-9_-]{0,63}\z/
  @transitions %{
    "running" => ~w(running completed failed cancelled),
    "completed" => ~w(completed),
    "failed" => ~w(failed),
    "cancelled" => ~w(cancelled)
  }

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec terminal_statuses() :: [String.t()]
  def terminal_statuses, do: @terminal_statuses

  @spec transition_allowed?(String.t(), String.t()) :: boolean()
  def transition_allowed?(current, next) do
    next in Map.get(@transitions, current, [])
  end

  schema "workflow_runs" do
    belongs_to(:agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey
    )

    field(:owner_session_id, :string)
    field(:reply_route, :map, default: %{})
    field(:source_actor_event_id, Ecto.UUID)
    field(:source_tool_call_id, :string)
    field(:title, :string)
    field(:script, :string)
    field(:args, :map, default: %{})
    field(:status, :string, default: "running")
    field(:concurrency, :integer)
    field(:max_agent_calls, :integer)
    field(:memo_bytes, :integer, default: 0)
    field(:model_profile, :string)
    field(:result_text, :string)
    field(:error, :map, default: %{})
    field(:completed_at, :utc_datetime_usec)
    field(:cleanup_completed_at, :utc_datetime_usec)

    has_many(:agent_calls, Ankole.Workflow.Schemas.AgentCall)

    timestamps()
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :agent_uid,
      :owner_session_id,
      :reply_route,
      :source_actor_event_id,
      :source_tool_call_id,
      :title,
      :script,
      :args,
      :status,
      :concurrency,
      :max_agent_calls,
      :memo_bytes,
      :model_profile,
      :result_text,
      :error,
      :completed_at,
      :cleanup_completed_at
    ])
    |> normalize_blank([
      :agent_uid,
      :owner_session_id,
      :source_tool_call_id,
      :title,
      :model_profile,
      :status
    ])
    |> validate_required([
      :agent_uid,
      :owner_session_id,
      :reply_route,
      :source_tool_call_id,
      :title,
      :script,
      :args,
      :status,
      :concurrency,
      :max_agent_calls,
      :memo_bytes,
      :error
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_transition(run.status)
    |> validate_length(:title, min: 1, max: 200)
    |> validate_nonblank(:script)
    |> validate_bytes(:script, 262_144)
    |> validate_number(:concurrency, greater_than_or_equal_to: 1, less_than_or_equal_to: 32)
    |> validate_number(:max_agent_calls,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 1_024
    )
    |> validate_number(:memo_bytes,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: @memo_budget_bytes
    )
    |> validate_optional_format(:model_profile, @model_profile)
    |> validate_optional_bytes(:result_text, 1_048_576)
    |> JSONPayload.validate_map(:reply_route)
    |> JSONPayload.validate_map(:args)
    |> validate_json_bytes(:args, 65_536)
    |> JSONPayload.validate_map(:error)
    |> foreign_key_constraint(:agent_uid)
    |> foreign_key_constraint(:source_actor_event_id)
    |> unique_constraint([:agent_uid, :owner_session_id, :source_tool_call_id],
      name: :workflow_runs_source_tool_call_index
    )
    |> check_constraint(:id, name: :workflow_runs_id_range)
    |> check_constraint(:reply_route, name: :workflow_runs_reply_route_object)
    |> check_constraint(:title, name: :workflow_runs_title_valid)
    |> check_constraint(:script, name: :workflow_runs_script_valid)
    |> check_constraint(:args, name: :workflow_runs_args_valid)
    |> check_constraint(:status, name: :workflow_runs_status_check)
    |> check_constraint(:concurrency, name: :workflow_runs_concurrency_range)
    |> check_constraint(:max_agent_calls, name: :workflow_runs_max_agent_calls_range)
    |> check_constraint(:memo_bytes, name: :workflow_runs_memo_bytes_range)
    |> check_constraint(:model_profile, name: :workflow_runs_model_profile_valid)
    |> check_constraint(:result_text, name: :workflow_runs_result_bounded)
    |> check_constraint(:error, name: :workflow_runs_error_object)
    |> check_constraint(:completed_at, name: :workflow_runs_lifecycle_check)
    |> check_constraint(:cleanup_completed_at, name: :workflow_runs_cleanup_lifecycle_check)
  end

  @spec creation_changeset(struct(), map()) :: Ecto.Changeset.t()
  def creation_changeset(run, attrs), do: changeset(run, attrs)

  defp validate_transition(changeset, nil), do: changeset

  defp validate_transition(changeset, current) do
    case fetch_change(changeset, :status) do
      {:ok, next} ->
        if transition_allowed?(current, next),
          do: changeset,
          else: add_error(changeset, :status, "cannot transition from #{current} to #{next}")

      :error ->
        changeset
    end
  end

  defp validate_nonblank(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_binary(value) and String.trim(value) != "", do: [], else: [{field, "can't be blank"}]
    end)
  end

  defp validate_optional_format(changeset, field, format) do
    validate_change(changeset, field, fn ^field, value ->
      if is_binary(value) and Regex.match?(format, value),
        do: [],
        else: [{field, "has invalid format"}]
    end)
  end

  defp validate_optional_bytes(changeset, field, maximum) do
    validate_change(changeset, field, fn ^field, value ->
      if is_binary(value) and byte_size(value) <= maximum,
        do: [],
        else: [{field, "is too large"}]
    end)
  end

  defp validate_bytes(changeset, field, maximum),
    do: validate_optional_bytes(changeset, field, maximum)

  defp validate_json_bytes(changeset, field, maximum) do
    validate_change(changeset, field, fn ^field, value ->
      case Torque.encode(value) do
        {:ok, encoded} when byte_size(encoded) <= maximum -> []
        {:ok, _encoded} -> [{field, "is too large"}]
        {:error, _reason} -> [{field, "must be JSON encodable"}]
      end
    end)
  end
end
