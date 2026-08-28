defmodule Ankole.Workflow.Schemas.AgentCall do
  @moduledoc """
  Durable queue and replay-memo entry for one Workflow Agent call.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Ecto.JSONPayload
  alias Ankole.Principals.Principal
  alias Ankole.Workflow.Schemas.Run

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @statuses ~w(queued running sleeping succeeded failed cancelled)
  @terminal_statuses ~w(succeeded failed cancelled)
  @model_profile ~r/\A[a-z][a-z0-9_-]{0,63}\z/
  @transitions %{
    "queued" => ~w(queued running failed cancelled),
    "running" => ~w(running queued sleeping succeeded failed cancelled),
    "sleeping" => ~w(sleeping running failed cancelled),
    "succeeded" => ~w(succeeded),
    "failed" => ~w(failed),
    "cancelled" => ~w(cancelled)
  }

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec terminal_statuses() :: [String.t()]
  def terminal_statuses, do: @terminal_statuses

  @spec transition_allowed?(String.t(), String.t()) :: boolean()
  def transition_allowed?(current, next), do: next in Map.get(@transitions, current, [])

  schema "workflow_agent_calls" do
    belongs_to(:run, Run, type: :id)

    belongs_to(:agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey
    )

    field(:call_seq, :integer)
    field(:arguments, :map)
    field(:label, :string)
    field(:model_profile, :string)
    field(:status, :string, default: "queued")
    field(:attempts, :integer, default: 0)
    field(:sleep_note, :string)
    field(:sleeping_until, :utc_datetime_usec)
    field(:wake_count, :integer, default: 0)
    field(:attention, :boolean, default: false)
    field(:result, :map)
    field(:error, :map, default: %{})

    timestamps()
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(call, attrs) do
    call
    |> cast(attrs, [
      :run_id,
      :agent_uid,
      :call_seq,
      :arguments,
      :label,
      :model_profile,
      :status,
      :attempts,
      :sleep_note,
      :sleeping_until,
      :wake_count,
      :attention,
      :result,
      :error
    ])
    |> normalize_blank([:agent_uid, :label, :model_profile, :status, :sleep_note])
    |> validate_required([
      :run_id,
      :agent_uid,
      :call_seq,
      :arguments,
      :status,
      :attempts,
      :error
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_transition(call.status)
    |> validate_number(:call_seq, greater_than_or_equal_to: 0)
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
    |> validate_number(:wake_count, greater_than_or_equal_to: 0)
    |> validate_length(:label, max: 200)
    |> validate_length(:sleep_note, max: 200)
    |> validate_optional_format(:model_profile, @model_profile)
    |> JSONPayload.validate_map(:arguments)
    |> validate_json_bytes(:arguments, 8_192)
    |> validate_optional_result()
    |> JSONPayload.validate_map(:error)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:agent_uid)
    |> unique_constraint([:run_id, :call_seq], name: :workflow_agent_calls_run_sequence_index)
    |> check_constraint(:id, name: :workflow_agent_calls_id_range)
    |> check_constraint(:call_seq, name: :workflow_agent_calls_sequence_nonnegative)
    |> check_constraint(:arguments, name: :workflow_agent_calls_arguments_valid)
    |> check_constraint(:label, name: :workflow_agent_calls_label_valid)
    |> check_constraint(:model_profile, name: :workflow_agent_calls_model_profile_valid)
    |> check_constraint(:status, name: :workflow_agent_calls_status_check)
    |> check_constraint(:attempts, name: :workflow_agent_calls_attempts_nonnegative)
    |> check_constraint(:wake_count, name: :workflow_agent_calls_wake_count_nonnegative)
    |> check_constraint(:sleep_note, name: :workflow_agent_calls_sleep_note_valid)
    |> check_constraint(:sleeping_until, name: :workflow_agent_calls_sleeping_deadline_present)
    |> check_constraint(:result, name: :workflow_agent_calls_result_valid)
    |> check_constraint(:error, name: :workflow_agent_calls_error_object)
  end

  @spec creation_changeset(struct(), map()) :: Ecto.Changeset.t()
  def creation_changeset(call, attrs), do: changeset(call, attrs)

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

  defp validate_optional_format(changeset, field, format) do
    validate_change(changeset, field, fn ^field, value ->
      if is_binary(value) and Regex.match?(format, value),
        do: [],
        else: [{field, "has invalid format"}]
    end)
  end

  defp validate_json_bytes(changeset, field, maximum) do
    validate_change(changeset, field, fn ^field, value ->
      case Torque.encode(value) do
        {:ok, encoded} when byte_size(encoded) <= maximum -> []
        {:ok, _encoded} -> [{field, "is too large"}]
        {:error, _reason} -> [{field, "must be JSON encodable"}]
      end
    end)
  end

  defp validate_optional_result(changeset) do
    validate_change(changeset, :result, fn :result, value ->
      case Torque.encode(value) do
        {:ok, encoded} when is_map(value) and byte_size(encoded) <= 32_768 -> []
        {:ok, _encoded} when not is_map(value) -> [result: "must be an object"]
        {:ok, _encoded} -> [result: "is too large"]
        {:error, _reason} -> [result: "must be JSON encodable"]
      end
    end)
  end
end
