defmodule Ankole.SubagentDelegations.Schemas.Delegation do
  @moduledoc """
  Durable subagent delegation work item.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Principals.Principal
  alias Ankole.Ecto.JsonPayload

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @statuses ~w(queued running waiting_on_user succeeded failed stopped)
  @terminal_statuses ~w(succeeded failed stopped)
  @running_statuses ~w(running waiting_on_user)
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

  @doc "Returns statuses that cannot transition to a different state."
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
    field(:runtime, :string, default: "codex")
    field(:title, :string)
    field(:prompt, :string)
    field(:reply_route, :map, default: %{})
    field(:attempts, :integer, default: 0)
    field(:workdir, :string)
    field(:status, :string)
    field(:queued_at, :utc_datetime_usec)
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
    field(:result, :map, default: %{})
    field(:error, :map, default: %{})
    field(:metadata, :map, default: %{})

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
      :title,
      :prompt,
      :reply_route,
      :attempts,
      :workdir,
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
      :session_id,
      :tool_call_id,
      :runtime_thread_id,
      :runtime,
      :title,
      :prompt,
      :workdir,
      :status
    ])
    |> validate_required([
      :agent_uid,
      :session_id,
      :runtime,
      :reply_route,
      :attempts,
      :status,
      :result,
      :error,
      :metadata
    ])
    |> validate_inclusion(:runtime, ["codex"])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
    |> JsonPayload.validate_map(:reply_route)
    |> JsonPayload.validate_map(:result, allow_datetime: true)
    |> JsonPayload.validate_map(:error, allow_datetime: true)
    |> JsonPayload.validate_map(:metadata, allow_datetime: true)
    |> foreign_key_constraint(:agent_uid)
    |> foreign_key_constraint(:actor_event_id)
    |> unique_constraint([:agent_uid, :session_id, :tool_call_id],
      name: :subagent_delegations_parent_tool_call_index
    )
    |> check_constraint(:runtime, name: :subagent_delegations_runtime_check)
    |> check_constraint(:reply_route, name: :subagent_delegations_reply_route_object)
    |> check_constraint(:attempts, name: :subagent_delegations_attempts_nonnegative)
    |> check_constraint(:status, name: :subagent_delegations_status_check)
    |> check_constraint(:result, name: :subagent_delegations_result_object)
    |> check_constraint(:error, name: :subagent_delegations_error_object)
    |> check_constraint(:metadata, name: :subagent_delegations_metadata_object)
  end

  @spec creation_changeset(struct(), map()) :: Ecto.Changeset.t()
  def creation_changeset(delegation, attrs) do
    delegation
    |> changeset(attrs)
    |> validate_required([:tool_call_id, :title, :prompt, :workdir])
    |> validate_change(:workdir, fn :workdir, path ->
      expanded = Path.expand(path)

      if expanded == "/workspace" or String.starts_with?(expanded, "/workspace/") do
        []
      else
        [workdir: "must stay under /workspace"]
      end
    end)
  end
end
